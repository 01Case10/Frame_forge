//! `ff bake` — absorb of `exit_gate/bake.py` + `ron_gen.py` + `build_baked.gd`.
//!
//! Pipeline (one binary, no Python, no Godot):
//! 1. Parse the scenario JSON (serde).
//! 2. Generate stepkit scenario RON (ported from `ron_gen.py`).
//! 3. Run `stepkit trace run --scenario X.ron --out Y.csv` (subprocess).
//! 4. Parse the trace CSV, compute per-frame displacements.
//! 5. Emit the 60 Hz baked chain behavior JSON directly (ported from
//!    `build_baked.gd`: each sim frame → one 2-frame state, linear easing,
//!    so the 2-tick total equals the sim displacement exactly).

use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{
    Condition, ConditionType, CurvePoint, EasingCurve, FrameBehavior, FrameState, SubStateMachine,
    Transition,
};
use serde::Deserialize;
use std::process::Command;

const SIM_TO_M: f32 = 0.01;

#[derive(Deserialize)]
struct Scenario {
    id: String,
    #[serde(default)]
    tags: Vec<String>,
    geometry: Vec<GeomBox>,
    start: ScenarioStart,
    #[serde(default)]
    camera_yaw_deg: f32,
    #[serde(default = "default_compare")]
    compare: String,
    inputs: Vec<InputBlock>,
}

fn default_compare() -> String {
    "GroundDefault".to_string()
}

#[derive(Deserialize)]
struct GeomBox {
    min: [f32; 3],
    max: [f32; 3],
    #[serde(default)]
    kind: i32,
}

#[derive(Deserialize)]
struct ScenarioStart {
    pos: [f32; 3],
    #[serde(default)]
    yaw_deg: f32,
    #[serde(default = "default_action")]
    action: String,
}

fn default_action() -> String {
    "Idle".to_string()
}

#[derive(Deserialize)]
struct InputBlock {
    frames: u32,
    stick: [i32; 2],
    buttons: i32,
}

fn fmt_num(v: f32) -> String {
    if v.fract() == 0.0 {
        format!("{:.1}", v)
    } else {
        format!("{}", v)
    }
}

/// Port of `ron_gen.py`.
fn to_ron(sc: &Scenario) -> String {
    let mut ron = String::from("(\n");
    ron.push_str(&format!("    id: \"{}\",\n", sc.id));
    ron.push_str("    tags: [\n");
    for t in &sc.tags {
        ron.push_str(&format!("        \"{}\",\n", t));
    }
    ron.push_str("    ],\n");
    ron.push_str("    geometry: [\n");
    for g in &sc.geometry {
        let mn = g
            .min
            .iter()
            .map(|v| fmt_num(*v))
            .collect::<Vec<_>>()
            .join(", ");
        let mx = g
            .max
            .iter()
            .map(|v| fmt_num(*v))
            .collect::<Vec<_>>()
            .join(", ");
        ron.push_str(&format!(
            "        Box((\n            min: ({}),\n            max: ({}),\n            kind: {},\n        )),\n",
            mn, mx, g.kind
        ));
    }
    ron.push_str("    ],\n");
    let pos = sc
        .start
        .pos
        .iter()
        .map(|v| fmt_num(*v))
        .collect::<Vec<_>>()
        .join(", ");
    ron.push_str("    start: (\n");
    ron.push_str(&format!("        pos: ({}),\n", pos));
    ron.push_str(&format!(
        "        yaw_deg: {},\n",
        fmt_num(sc.start.yaw_deg)
    ));
    ron.push_str(&format!("        action: \"{}\",\n", sc.start.action));
    ron.push_str("    ),\n");
    ron.push_str("    camera: Fixed(\n");
    ron.push_str(&format!(
        "        yaw_deg: {},\n",
        fmt_num(sc.camera_yaw_deg)
    ));
    ron.push_str("    ),\n");
    ron.push_str("    inputs: [\n");
    for seg in &sc.inputs {
        assert!(
            (-128..=127).contains(&seg.stick[0]) && (-128..=127).contains(&seg.stick[1]),
            "stick out of i8 range: {:?}",
            seg.stick
        );
        ron.push_str(&format!(
            "        Hold(\n            frames: {},\n            stick: ({}, {}),\n            buttons: {},\n        ),\n",
            seg.frames, seg.stick[0], seg.stick[1], seg.buttons
        ));
    }
    ron.push_str("    ],\n");
    ron.push_str(&format!("    compare: {},\n", sc.compare));
    ron.push_str(")\n");
    ron
}

fn linear_easing() -> EasingCurve {
    EasingCurve {
        points: vec![
            CurvePoint {
                pos: [0.0, 0.0],
                left_tangent: 0.0,
                right_tangent: 1.0,
            },
            CurvePoint {
                pos: [1.0, 1.0],
                left_tangent: 1.0,
                right_tangent: 0.0,
            },
        ],
        min_value: 0.0,
        max_value: 1.0,
    }
}

/// Port of `build_baked.gd`: displacement JSON -> 60 Hz chain behavior.
fn build_chain(displacements: &[Vec3], name: &str) -> FrameBehavior {
    let n = displacements.len();
    let mut states: Vec<FrameState> = Vec::with_capacity(n);
    for (i, d) in displacements.iter().enumerate() {
        let v = *d * SIM_TO_M;
        let len = v.length();
        let dir = if len * len > 1e-18 {
            v.normalized()
        } else {
            ZERO
        };
        states.push(FrameState {
            state_name: format!("f{}", i),
            displacement: len,
            direction: dir.to_array(),
            duration_frames: 2,
            easing: linear_easing(),
            ..Default::default()
        });
    }
    for (i, st) in states.iter_mut().enumerate() {
        let target = format!("f{}", (i + 1).min(n - 1));
        st.transitions = vec![Transition {
            condition: Condition {
                cond_type: ConditionType::OnComplete,
                ..Default::default()
            },
            target_state_name: target,
            ..Default::default()
        }];
    }
    let machine = SubStateMachine {
        machine_name: "Baked".to_string(),
        states,
        entry_state_name: "f0".to_string(),
        ..Default::default()
    };
    FrameBehavior {
        behavior_name: name.to_string(),
        sub_machines: vec![machine],
        ..Default::default()
    }
}

pub fn run(
    scenario_path: &str,
    out_path: &str,
    name: &str,
    stepkit_bin: &str,
) -> Result<(), String> {
    let text = std::fs::read_to_string(scenario_path).map_err(|e| format!("scenario: {}", e))?;
    let sc: Scenario = serde_json::from_str(&text).map_err(|e| format!("scenario parse: {}", e))?;

    // 1-2. RON to a temp file.
    let workdir = std::env::temp_dir().join("ff_bake");
    std::fs::create_dir_all(&workdir).map_err(|e| format!("workdir: {}", e))?;
    let ron_path = workdir.join(format!("{}.ron", sc.id));
    let csv_path = workdir.join(format!("{}.csv", sc.id));
    std::fs::write(&ron_path, to_ron(&sc)).map_err(|e| format!("ron write: {}", e))?;

    // 3. stepkit trace run.
    let status = Command::new(stepkit_bin)
        .args(["trace", "run", "--scenario"])
        .arg(&ron_path)
        .args(["--out"])
        .arg(&csv_path)
        .status()
        .map_err(|e| format!("stepkit: {}", e))?;
    if !status.success() {
        return Err(format!("stepkit trace run failed: {}", status));
    }

    // 4. Parse CSV positions.
    let csv_text = std::fs::read_to_string(&csv_path).map_err(|e| format!("csv read: {}", e))?;
    let mut lines = csv_text.lines();
    let header: Vec<&str> = lines.next().ok_or("empty csv")?.split(',').collect();
    let col = |n: &str| {
        header
            .iter()
            .position(|&h| h.trim() == n)
            .ok_or(format!("csv missing column {}", n))
    };
    let (ix, iy, iz) = (col("pos_x")?, col("pos_y")?, col("pos_z")?);
    let mut positions: Vec<Vec3> = Vec::new();
    for line in lines {
        let f: Vec<&str> = line.split(',').collect();
        if f.len() <= ix.max(iy).max(iz) {
            continue;
        }
        positions.push(Vec3::new(
            f[ix].trim().parse::<f32>().map_err(|e| e.to_string())?,
            f[iy].trim().parse::<f32>().map_err(|e| e.to_string())?,
            f[iz].trim().parse::<f32>().map_err(|e| e.to_string())?,
        ));
    }
    if positions.len() < 2 {
        return Err("trace has fewer than 2 frames".to_string());
    }

    // 5. Displacements -> chain -> JSON.
    let displacements: Vec<Vec3> = positions.windows(2).map(|w| w[1] - w[0]).collect();
    let bh = build_chain(&displacements, name);
    let json = serde_json::to_string_pretty(&bh).map_err(|e| e.to_string())?;
    std::fs::write(out_path, json).map_err(|e| format!("write {}: {}", out_path, e))?;
    println!(
        "baked {} displacements ({} frames) -> {}",
        displacements.len(),
        positions.len(),
        out_path
    );
    Ok(())
}
