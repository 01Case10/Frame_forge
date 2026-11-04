//! G-7 built-in: SMG ledge hang (MarioHang.cpp, verbatim transcription).
//!
//! Implements Super Mario Galaxy's ledge-hang phase machine, transcribed
//! from `~/workspace/petari/src/Game/Player/MarioHang.cpp` (see
//! `~/workspace/smg_transcription/mariohang.md`).
//!
//! Phase machine (`_12` in the decomp):
//!   0 = hanging. Hanging idle has ZERO displacement — `update()` contains
//!       no shimmy, no drift, no stick-driven movement while hanging
//!       (MarioHang.cpp:563-642). Only guards run.
//!   1 = climb-out commit. No movement; picks the climb-out animation
//!       (MarioHang.cpp:653-663).
//!   2 = climb-out finishing. Per tick:
//!         `addVelocity(getFrontVec() * 6.0f)` (MarioHang.cpp:665)
//!       while not grounded. Climb commits only after `_14 > 18` ticks of
//!       hang have elapsed (MarioHang.cpp:705, :729-732).
//!
//! Stick-down drop (`direction == 2`, MarioHang.cpp:708-727):
//!   `addTrans(getPlayer()->mFrontVec * -100.0f, "Module")` — a single
//!   push-off tick, then `tryDrop()` (enters free fall with ~zero velocity).
//!
//! Params: none consumed. Writes `smg_hang_done=1.0` when the scripted
//! climb-out (or the drop push-off) finishes, so the authored behavior can
//! transition out.
//!
//! SIMPLIFICATIONS (no analytic form in a position-agnostic core):
//! - No clearance raycasts (`tryClimb`'s front/side rays) and no wall-moved
//!   / sensor-mismatch branches: the wall fixture is assumed static and
//!   clear. Side shifts (+/-15) are not modeled.
//! - Phase-2 duration is scripted (10 ticks, `SMG_HANG_CLIMB_TICKS`);
//!   the decomp ends phase 2 when the climb animation terminates.
//! - The grab-animation latch (`_1D`, drop deferred to first post-grab
//!   tick) is not modeled: stick-down drops immediately.
//! - The slip-up countdown (`_16`, `tryHangSlipUp` 12.0 up / 5.0 forward)
//!   is not modeled — the A-press arm path only.
//! - The entry nudge loop (+1 fwd / +1 down, up to 10 ticks) is not
//!   modeled; the state starts at the grab pose.
//!
//! Transitions stay authored (D4): the game/behavior owns state changes;
//! this logic only computes per-tick deltas and raises `smg_hang_done`.

use crate::logic::{param_f32, LogicFactory, StateCtx, StateLogic};
use crate::vec3::{Vec3, ZERO};
use std::collections::HashMap;

/// Debug logging for SMG hang. Enabled via FF_DEBUG=1 env var.
fn dbg_enabled() -> bool {
    std::env::var("FF_DEBUG").map(|v| v == "1").unwrap_or(false)
}
macro_rules! smg_dbg {
    ($($arg:tt)*) => {
        if dbg_enabled() {
            eprintln!($($arg)*);
        }
    };
}

/// SMG units to meters (ff diff compares in meters; 1 SMG unit ≈ 1 cm).
const UNIT_TO_M: f32 = 0.01;

/// Hang ticks required before an A-press climb can commit
/// (MarioHang.cpp:705, 729: `_14 > 18`).
const SMG_HANG_CLIMB_GATE: u32 = 18;

/// Scripted phase-2 duration in ticks. The decomp ends phase 2 when the
/// climb animation terminates (animation length is data, not code);
/// documented simplification — see module docs.
const SMG_HANG_CLIMB_TICKS: u32 = 10;

/// Per-tick forward velocity added during climb-out phase 2
/// (MarioHang.cpp:665: `addVelocity(getFrontVec() * 6.0f)`).
const SMG_HANG_CLIMB_SPEED: f32 = 6.0;

/// Stick-down drop push-off (MarioHang.cpp:714:
/// `addTrans(getPlayer()->mFrontVec * -100.0f, "Module")`), single tick.
const SMG_HANG_DROP_PUSH: f32 = -100.0;

fn write_f32(params: &mut HashMap<String, crate::model::ParamValue>, name: &str, v: f32) {
    params.insert(name.to_string(), crate::model::ParamValue::Float(v as f64));
}

pub struct SmgHang {
    hang_ticks: u32,
    phase: u32, // 0 = hang, 1 = climb-out commit, 2 = climb-out finishing
    climb_armed: bool,
    climb_ticks: u32, // phase-2 counter
}

impl SmgHang {
    pub fn new() -> Self {
        Self {
            hang_ticks: 0,
            phase: 0,
            climb_armed: false,
            climb_ticks: 0,
        }
    }

    pub fn factory() -> LogicFactory {
        Box::new(|| Box::new(SmgHang::new()))
    }

    fn facing(&self, ctx: &StateCtx) -> Vec3 {
        let yaw_deg = param_f32(ctx.params, "smg_facing_yaw", *ctx.facing_yaw);
        let yr = yaw_deg.to_radians();
        Vec3::new(yr.sin(), 0.0, yr.cos())
    }
}

impl Default for SmgHang {
    fn default() -> Self {
        Self::new()
    }
}

impl StateLogic for SmgHang {
    fn on_enter(&mut self, ctx: &mut StateCtx) {
        self.hang_ticks = 0;
        self.phase = 0;
        self.climb_armed = false;
        self.climb_ticks = 0;
        // Clear any stale completion flag so a previous hang's done signal
        // cannot instantly re-trigger the exit transition.
        write_f32(ctx.params, "smg_hang_done", 0.0);
        smg_dbg!("SMG_DBG hang on_enter frame={}", ctx.frame);
    }

    fn on_tick(&mut self, ctx: &mut StateCtx) {
        // The decomp's phase-0 body runs no movement at all; the push-off
        // and climb branches below mirror `update()`'s guard order.
        *ctx.delta = ZERO;

        match self.phase {
            0 => {
                // Update head (MarioHang.cpp:580): `_14++`.
                self.hang_ticks += 1;

                // Stick-down drop (MarioHang.cpp:708-727): push-off once,
                // then signal done. Decomp defers during the grab anim
                // (`_1D` latch); simplification: drop immediately.
                let stick_down = ctx.input.held.contains("ff_drop") || ctx.stick[1] < -0.5;
                if stick_down {
                    *ctx.delta = self.facing(ctx) * (SMG_HANG_DROP_PUSH * UNIT_TO_M);
                    write_f32(ctx.params, "smg_hang_done", 1.0);
                    smg_dbg!(
                        "SMG_DBG hang frame={}: stick-down drop, push-off {}",
                        ctx.frame,
                        SMG_HANG_DROP_PUSH
                    );
                    return;
                }

                // A-press climb (MarioHang.cpp:683-684, 729-732): arm on
                // press (`_1B`), commit only once `_14 > 18`.
                if ctx.input.just_pressed.contains("ff_jump") {
                    self.climb_armed = true;
                    smg_dbg!(
                        "SMG_DBG hang frame={}: A pressed, hang_ticks={} (gate {})",
                        ctx.frame,
                        self.hang_ticks,
                        SMG_HANG_CLIMB_GATE
                    );
                }
                if self.climb_armed && self.hang_ticks > SMG_HANG_CLIMB_GATE {
                    // `tryClimb` clearance assumed clear (scripted fixture).
                    self.climb_armed = false;
                    self.phase = 1;
                    smg_dbg!("SMG_DBG hang frame={}: climb committed (phase 1)", ctx.frame);
                }
            }
            1 => {
                // Climb-out commit (MarioHang.cpp:653-663): no movement;
                // animation picked, then `_12++`.
                self.phase = 2;
                self.climb_ticks = 0;
                smg_dbg!("SMG_DBG hang frame={}: phase 2 (climb-out)", ctx.frame);
            }
            _ => {
                // Climb-out finishing (MarioHang.cpp:664-672): per tick
                // `addVelocity(getFrontVec() * 6.0f)` while not grounded.
                // The decomp ends phase 2 on animation termination;
                // scripted duration here (documented above).
                self.climb_ticks += 1;
                *ctx.delta = self.facing(ctx) * (SMG_HANG_CLIMB_SPEED * UNIT_TO_M);
                smg_dbg!(
                    "SMG_DBG hang frame={}: phase 2 tick {}/{} delta=({:.4},{:.4},{:.4})",
                    ctx.frame,
                    self.climb_ticks,
                    SMG_HANG_CLIMB_TICKS,
                    ctx.delta.x,
                    ctx.delta.y,
                    ctx.delta.z
                );
                if self.climb_ticks >= SMG_HANG_CLIMB_TICKS {
                    write_f32(ctx.params, "smg_hang_done", 1.0);
                }
            }
        }
    }

    fn on_exit(&mut self, _ctx: &mut StateCtx) {}
}
