//! `ff diff` — differential harness: replay a behavior against a stepkit
//! oracle CSV and compare 3D positions per frame.
//!
//! Mirrors `exit_gate/run_gate.gd`: same input mapping, same sampling,
//! same tolerances (stepkit cm): mean < 0.5, max < 2.0, final < 1.0.

use frameforge_core::input::TickInput;
use frameforge_core::tick::{ContactState, Runtime};
use frameforge_core::vec3::Vec3;
use frameforge_core::FrameBehavior;
use std::collections::{HashMap, HashSet};
use std::fs;

const SIM_TO_M: f32 = 0.01;
const MEAN_TOL: f32 = 0.5;
const MAX_TOL: f32 = 2.0;
const FINAL_TOL: f32 = 1.0;

pub struct Oracle {
    pub positions: Vec<Vec3>,         // meters
    pub inputs: Vec<(f32, f32, i32)>, // stick_x, stick_y, buttons
}

pub fn load_oracle(path: &str) -> Result<Oracle, String> {
    let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut lines = text.lines();
    let header: Vec<&str> = lines.next().ok_or("empty oracle")?.split(',').collect();
    let col = |name: &str| {
        header
            .iter()
            .position(|&h| h.trim() == name)
            .ok_or_else(|| format!("missing column {}", name))
    };
    let (ix, iy, iz) = (col("pos_x")?, col("pos_y")?, col("pos_z")?);
    let (sx, sy, bt) = (col("stick_x")?, col("stick_y")?, col("buttons")?);
    let mut positions = Vec::new();
    let mut inputs = Vec::new();
    for line in lines {
        let f: Vec<&str> = line.split(',').collect();
        if f.len() <= ix.max(iy).max(iz) {
            continue;
        }
        let px: f32 = f[ix].trim().parse().map_err(|e| format!("pos_x: {}", e))?;
        let py: f32 = f[iy].trim().parse().map_err(|e| format!("pos_y: {}", e))?;
        let pz: f32 = f[iz].trim().parse().map_err(|e| format!("pos_z: {}", e))?;
        positions.push(Vec3::new(px * SIM_TO_M, py * SIM_TO_M, pz * SIM_TO_M));
        let ax: f32 = f[sx].trim().parse().unwrap_or(0.0);
        let ay: f32 = f[sy].trim().parse().unwrap_or(0.0);
        let b: i32 = f[bt].trim().parse().unwrap_or(0);
        inputs.push((ax, ay, b));
    }
    if positions.is_empty() {
        return Err("no oracle rows".to_string());
    }
    Ok(Oracle { positions, inputs })
}

fn set_axis(
    held: &mut HashSet<String>,
    strengths: &mut HashMap<String, f32>,
    neg: &str,
    pos: &str,
    v: f32,
) {
    if v > 0.05 {
        held.insert(pos.to_string());
        strengths.insert(pos.to_string(), v.min(1.0));
    } else if v < -0.05 {
        held.insert(neg.to_string());
        strengths.insert(neg.to_string(), (-v).min(1.0));
    }
}

/// Mirror of run_gate `_replay_input`.
/// NOTE the arg order: _set_axis("ff_right", "ff_left", sx/80) presses
/// ff_left for stick_x+ (sim stick_x+ -> -X world).
pub fn tick_input(sx: f32, sy: f32, buttons: i32) -> TickInput {
    let mut held = HashSet::new();
    let mut strengths = HashMap::new();
    set_axis(&mut held, &mut strengths, "ff_right", "ff_left", sx / 80.0);
    set_axis(&mut held, &mut strengths, "ff_fwd", "ff_back", sy / 80.0);
    for (bit, name) in [(0x1, "ff_jump"), (0x2, "ff_attack"), (0x4, "ff_crouch")] {
        if buttons & bit != 0 {
            held.insert(name.to_string());
            strengths.insert(name.to_string(), 1.0);
        }
    }
    TickInput { held, strengths }
}

pub struct DiffResult {
    pub frames: usize,
    pub mean: f32,
    pub max: f32,
    pub final_err: f32,
    pub passed: bool,
}

pub fn run(
    behavior_path: &str,
    oracle: &Oracle,
    ticks_per_frame: u32,
) -> Result<DiffResult, String> {
    let behavior = FrameBehavior::load_json(behavior_path)?;
    let mut rt = Runtime::new(behavior);
    let tpf = ticks_per_frame.max(1) as usize;

    let mut pos = oracle.positions[0];
    let mut samples = vec![pos];
    let total_ticks = (oracle.positions.len() - 1) * tpf;
    for tick_idx in 0..total_ticks {
        let fi = (tick_idx / tpf).min(oracle.inputs.len() - 1);
        let (sx, sy, buttons) = oracle.inputs[fi];
        let input = tick_input(sx, sy, buttons);
        // Flat-ground contact model (the 14 differentials need no walls;
        // no behavior reads contact edges).
        let contact = ContactState {
            floor: pos.y <= 1e-4,
            ..Default::default()
        };
        let d = rt.tick(&input, &contact);
        pos = pos + d;
        if (tick_idx + 1) % tpf == 0 {
            samples.push(pos);
        }
    }

    let n = samples.len().min(oracle.positions.len());
    let mut mean = 0.0f32;
    let mut mx = 0.0f32;
    for (k, s) in samples.iter().enumerate().take(n) {
        let e = (*s - oracle.positions[k]).length() * 100.0;
        mean += e;
        mx = mx.max(e);
    }
    mean /= n.max(1) as f32;
    let final_err = if n > 0 {
        (samples[n - 1] - oracle.positions[n - 1]).length() * 100.0
    } else {
        999.0
    };
    let passed = mean < MEAN_TOL && mx < MAX_TOL && final_err < FINAL_TOL;
    Ok(DiffResult {
        frames: n,
        mean,
        max: mx,
        final_err,
        passed,
    })
}
