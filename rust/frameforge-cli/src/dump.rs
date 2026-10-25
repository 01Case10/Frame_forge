//! `ff dump` — per-tick trace for debugging differentials.
//! Loads a behavior JSON + scenario JSON, replays inputs, prints a table:
//! tick, position (m), delta (m), per-track states.

use crate::diff;
use frameforge_core::tick::{ContactState, Runtime};
use frameforge_core::vec3::Vec3;
use frameforge_core::FrameBehavior;
use serde::Deserialize;

#[derive(Deserialize)]
struct Scenario {
    inputs: Vec<InputBlock>,
    #[serde(default)]
    start: ScenarioStart,
}

#[derive(Deserialize)]
struct InputBlock {
    frames: u32,
    stick: [f32; 2],
    buttons: i32,
}

#[derive(Deserialize, Default)]
struct ScenarioStart {
    #[serde(default)]
    pos: [f32; 3],
}

pub fn run(behavior_path: &str, scenario_path: &str, tpf: u32) -> Result<(), String> {
    let bh = FrameBehavior::load_json(behavior_path)
        .map_err(|e| format!("behavior {}: {}", behavior_path, e))?;
    let text = std::fs::read_to_string(scenario_path).map_err(|e| format!("scenario: {}", e))?;
    let sc: Scenario = serde_json::from_str(&text).map_err(|e| format!("scenario parse: {}", e))?;

    // Expand input blocks to per-frame (stick_x, stick_y, buttons).
    let mut frames: Vec<(f32, f32, i32)> = Vec::new();
    for b in &sc.inputs {
        for _ in 0..b.frames {
            frames.push((b.stick[0], b.stick[1], b.buttons));
        }
    }
    if frames.is_empty() {
        return Err("scenario has no input frames".to_string());
    }

    let mut rt = Runtime::new(bh);
    let mut pos = Vec3::new(
        sc.start.pos[0] * 0.01,
        sc.start.pos[1] * 0.01,
        sc.start.pos[2] * 0.01,
    );
    let total_ticks = frames.len() as u32 * tpf;

    println!("tick,x,y,z,dx,dy,dz,states");
    for tick_idx in 0..total_ticks {
        let fi = ((tick_idx / tpf) as usize).min(frames.len() - 1);
        let (sx, sy, buttons) = frames[fi];
        let input = diff::tick_input(sx, sy, buttons);
        // Flat-ground contact model (same as ff diff).
        let contact = ContactState {
            floor: pos.y <= 1e-4,
            ..Default::default()
        };
        let d = rt.tick(&input, &contact);
        pos = pos + d;
        let states: Vec<String> = rt
            .track_states()
            .into_iter()
            .map(|(m, s, f)| format!("{}/{}@{}", m, s, f))
            .collect();
        println!(
            "{},{:.6},{:.6},{:.6},{:.6},{:.6},{:.6},{}",
            tick_idx,
            pos.x,
            pos.y,
            pos.z,
            d.x,
            d.y,
            d.z,
            states.join(";")
        );
    }
    Ok(())
}
