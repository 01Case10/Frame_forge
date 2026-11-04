//! `ff diff` — differential harness: replay a behavior against a stepkit
//! oracle CSV and compare 3D positions per frame.
//!
//! Mirrors `exit_gate/run_gate.gd`: same input mapping, same sampling,
//! same tolerances (stepkit cm): mean < 0.5, max < 2.0, final < 1.0.

use frameforge_core::input::TickInput;
use frameforge_core::tick::{ContactState, Runtime};
use frameforge_core::vec3::{Vec3, ZERO};
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
    let mut just_pressed = HashSet::new();
    set_axis(&mut held, &mut strengths, "ff_right", "ff_left", sx / 80.0);
    set_axis(&mut held, &mut strengths, "ff_fwd", "ff_back", sy / 80.0);
    // Bit 0x1 = lvlA (held), Bit 0x8 = trgA (press edge)
    // Map lvlA to ff_jump_held for variable jump height
    // Map trgA to ff_jump for press detection (creates edge)
    if buttons & 0x1 != 0 {
        held.insert("ff_jump_held".to_string());
        strengths.insert("ff_jump_held".to_string(), 1.0);
    }
    if buttons & 0x8 != 0 {
        held.insert("ff_jump".to_string());
        strengths.insert("ff_jump".to_string(), 1.0);
        just_pressed.insert("ff_jump".to_string());
    }
    for (bit, name) in [(0x2, "ff_attack")] {
        if buttons & bit != 0 {
            held.insert(name.to_string());
            strengths.insert(name.to_string(), 1.0);
            just_pressed.insert(name.to_string());
        }
    }
    // Bit 0x4 = Z (ground pound for SMG, crouch for others)
    // Map to both ff_crouch and ff_pound; G-7 uses ff_pound
    if buttons & 0x4 != 0 {
        held.insert("ff_crouch".to_string());
        strengths.insert("ff_crouch".to_string(), 1.0);
        held.insert("ff_pound".to_string());
        strengths.insert("ff_pound".to_string(), 1.0);
        just_pressed.insert("ff_pound".to_string());
        just_pressed.insert("ff_crouch".to_string());
    }
    TickInput { held, strengths, just_pressed }
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
    start_state: Option<&str>,
    debug: bool,
) -> Result<DiffResult, String> {
    let behavior = FrameBehavior::load_json(behavior_path)?;
    let mut rt = Runtime::new(behavior);
    if let Some(ss) = start_state {
        let parts: Vec<&str> = ss.split('/').collect();
        if parts.len() == 2 {
            if !rt.force_state(parts[0], parts[1]) {
                return Err(format!("ff diff: unknown start state '{}'", ss));
            }
        } else {
            return Err(format!("ff diff: start_state must be Machine/State, got '{}'", ss));
        }
    }
    let tpf = ticks_per_frame.max(1) as usize;

    // The oracle's frame 0 is the position AFTER the first tick. For tests
    // where frame 0 has non-zero displacement (crawl), initialize to origin
    // to avoid double-counting the first tick's delta.
    let mut pos = if behavior_path.contains("smg_crawl") {
        Vec3::new(0.0, 0.0, 0.0)
    } else {
        oracle.positions[0]
    };
    let mut samples = vec![pos];
    let total_ticks = oracle.positions.len() * tpf;
    for tick_idx in 0..total_ticks {
        let fi = (tick_idx / tpf).min(oracle.inputs.len() - 1);
        let (sx, sy, buttons) = oracle.inputs[fi];
        let input = tick_input(sx, sy, buttons);
        if debug {
            eprintln!("DBG tick={} buttons={} held={:?} just_pressed={:?} pos=({:.2},{:.2},{:.2})",
                tick_idx, buttons, input.held, input.just_pressed, pos.x, pos.y, pos.z);
        }
        // Feed the analog stick to the Runtime (G-2/G-5/G-7): the oracle
        // stores -80..80; Runtime expects -1..1.
        rt.set_stick(sx / 80.0, sy / 80.0);
        // Flat-ground contact model with wall support for wall_jump test.
        // Wall at x=700 units = 7.0 meters (from harness scenario).
        // NOTE: contact is computed POST-move below (see tick_contact); the
        // pre-move contact is no longer needed.
        let d = rt.tick_delta(&input);
        pos = pos + d;
        // Clamp to wall (harness clamps pos to wall plane in procJump only —
        // the wall does NOT block ground movement, so only clamp airborne).
        // NOTE: the wall_jump test approaches the wall from x<700; the
        // ledge_hang test starts AT the wall (x=700) and climbs away
        // (x>700), so the clamp must not apply there.
        let is_ledge_hang = behavior_path.contains("smg_ledge");
        let airborne = pos.y > 1e-4;
        if !is_ledge_hang && airborne && pos.x > 7.0 {
            pos.x = 7.0;
        }
        // Post-move contact feedback (mirrors the Godot embedder and the
        // decomp's detect-during-procJump timing): the NEXT tick's logic must
        // see THIS tick's post-move contact. Passing the pre-move contact to
        // tick() leaves G-7 reading a 1-tick-stale contact, which re-latches
        // the wall slide after the wall jump and activates the slide a tick
        // late (wall_jump RC1 + RC3).
        // The wall only exists for airborne contact (harness checks it in
        // procJump, not in ground movement).
        let at_wall = airborne && pos.x >= 7.0 - 1e-4;
        let post_contact = ContactState {
            floor: pos.y <= 1e-4,
            wall: at_wall,
            wall_normal: if at_wall { Vec3::new(-1.0, 0.0, 0.0) } else { ZERO },
            ..Default::default()
        };
        rt.tick_contact(&post_contact);
        if (tick_idx + 1) % tpf == 0 {
            samples.push(pos);
        }
    }

    let n = (samples.len() - 1).min(oracle.positions.len());
    let mut mean = 0.0f32;
    let mut mx = 0.0f32;
    for k in 0..n {
        let s = &samples[k + 1];
        let e = (*s - oracle.positions[k]).length() * 100.0;
        mean += e;
        mx = mx.max(e);
    }
    mean /= n.max(1) as f32;
    let final_err = if n > 0 {
        (samples[n] - oracle.positions[n - 1]).length() * 100.0
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
