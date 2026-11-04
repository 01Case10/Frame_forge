//! G-7 built-in: SMG procedural physics.
//!
//! Implements Super Mario Galaxy's per-tick movement integrators, transcribed
//! from the Petari decompilation (see ~/workspace/petari-harness).
//!
//! Two modes, selected by the `smg_mode` param ("walk" or "jump"):
//!
//! Walk (MarioWalk.cpp `updateWalkSpeed`, MarioMove.cpp `decideInertia`):
//!   target = sWalkTargetTable[decideWalkSpeed(stick)]
//!   inertia = (1-w)*mInertiaStandardStop + w*mInertiaStandardMax
//!   w = w*inertia + target*(1-inertia)
//!   delta = facing * (mWalkSpeed * w)
//!
//! Jump (MarioJump.cpp `tryJump`/`procJump`):
//!   on enter: jumpVec = facing * (walkSpeed * mJumpFrontSpeed) + up * v0
//!   per tick: jumpVec.y -= g * scale (scale=0.5 while rising & jump held)
//!             clamp fall to terminal velocity
//!             delta = jumpVec
//!
//! Params (all optional, defaults = MarioConstTable table 0):
//! - `smg_mode`: "walk" | "jump"
//! - Walk: `smg_walk_table_speed` (13.0), `smg_inertia_stop` (0.94),
//!   `smg_inertia_max` (0.9)
//! - Jump: `smg_jump_v0` (22.0), `smg_jump_gravity` (1.8),
//!   `smg_jump_hold_scale` (0.5), `smg_terminal_velocity` (35.0),
//!   `smg_jump_front_speed` (12.5)
//! - `smg_walk_speed_param`: blackboard name for walk.speed ("walk.speed").
//!   The walk logic writes it each tick; the jump logic reads it on enter.
//!
//! Transitions stay authored (D4): the game/behavior owns state changes;
//! this logic only computes per-tick deltas.

use crate::logic::{param_bool, param_f32, LogicFactory, StateCtx, StateLogic};
use crate::vec3::{Vec3, ZERO};
use std::collections::HashMap;
use std::f32::consts::PI;

/// Debug logging for SMG physics. Enabled via FF_DEBUG=1 env var.
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

// sSpeedTableA / sWalkTargetTable from MarioWalk.cpp.
const SPEED_TABLE_A: [f32; 7] = [0.15, 0.3, 0.45, 0.6, 0.7, 0.85, 0.99];
const WALK_TARGET_TABLE: [f32; 8] = [0.0, 0.15, 0.25, 0.4, 0.5, 0.6, 0.8, 1.0];

// Jump chaining (MarioJump.cpp): mJumpHeight table, connect time/speed.
// Extended to cover all jump types: 0=single, 1=double, 2=triple, 3=belly,
// 4=turn, 5=squat, 6=back, 7=wall, 8=spin
const JUMP_HEIGHTS: [f32; 9] = [22.0, 26.0, 36.0, 24.0, 32.0, 15.0, 32.0, 22.0, 12.0];
const JUMP_GRAVITIES: [f32; 9] = [1.8, 1.8, 1.8, 1.8, 1.8, 1.8, 1.8, 1.8, 0.25];
// Spin jump uses special gravity (0.25, floaty)
const JUMP_CONNECT_TIME: u32 = 7;  // mJumpConnectTime
const JUMP_CONNECT_SPEED: f32 = 0.6;  // mJumpConnectSpeed (min walkSpeed for triple)

pub struct SmgPhysics {
    mode_walk: bool,
    walk_speed: f32,
    jump_vec: Vec3,
    jump_airborne: bool,
    jump_entered: bool,
    jump_y: f32,
    jump_type: u32,  // 0=single, 1=double, 2=triple (for chaining)
    pound_active: bool,  // Ground pound (hip-drop) active
    wall_sliding: bool,  // Wall slide active
    just_wall_jumped: bool, // Set on the wall-jump press tick; blocks slide
                            // re-activation for one tick (we're still at the
                            // wall since the press tick had zero delta).
    chain_pending: bool, // In-place chain armed: next tick outputs zero delta
                        // (decomp tryJump frame applies no movement)
    // Playable-moveset opt-ins (default false = harness-verbatim; the
    // differential oracles come from the harness, whose walkTick never turns
    // and whose jumpTick never calls doAirWalk):
    // - `smg_turn_to_stick`: turn facing toward the stick's world direction
    //   (MarioMove.cpp turn block).
    // - `smg_air_control`: drift jumpVec toward the stick in air
    //   (MarioJump.cpp doAirWalk, harness simplified form).
    turn_to_stick: bool,
    air_control: bool,
    // tunables (loaded on enter)
    walk_table_speed: f32,
    inertia_stop: f32,
    inertia_max: f32,
    inertia_rest_stop: f32,
    inertia_jump_finish: f32,
    ice_mode: bool,
    inertia_ice_stop: f32,
    inertia_ice_max: f32,
    inertia_ice_rest: f32,
    slip_mode: bool,
    inertia_slip_stop: f32,
    inertia_slip_max: f32,
    inertia_slip_rest: f32,
    land_timer: u32,
    jump_v0: f32,
    jump_gravity: f32,
    jump_hold_scale: f32,
    terminal_velocity: f32,
    jump_front_speed: f32,
    walk_speed_param: String,
}

impl SmgPhysics {
    pub fn new() -> Self {
        Self {
            mode_walk: true,
            walk_speed: 0.0,
            jump_vec: ZERO,
            jump_airborne: false,
            jump_entered: false,
            jump_y: 0.0,
            jump_type: 0,
            pound_active: false,
            wall_sliding: false,
            just_wall_jumped: false,
            chain_pending: false,
            turn_to_stick: false,
            air_control: false,
            walk_table_speed: 13.0,
            inertia_stop: 0.94,
            inertia_max: 0.9,
            inertia_rest_stop: 0.85,
            inertia_jump_finish: 0.8,
            ice_mode: false,
            inertia_ice_stop: 0.985,
            inertia_ice_max: 0.995,
            inertia_ice_rest: 0.992,
            slip_mode: false,
            inertia_slip_stop: 0.98,
            inertia_slip_max: 0.99,
            inertia_slip_rest: 0.98,
            land_timer: 999,
            jump_v0: 22.0,
            jump_gravity: 1.8,
            jump_hold_scale: 0.5,
            terminal_velocity: 35.0,
            jump_front_speed: 12.5,
            walk_speed_param: "walk.speed".to_string(),
        }
    }

    pub fn factory() -> LogicFactory {
        Box::new(|| Box::new(SmgPhysics::new()))
    }

    fn load_params(&mut self, params: &HashMap<String, crate::model::ParamValue>) {
        use crate::model::ParamValue;
        match params.get("smg_mode") {
            Some(ParamValue::Str(s)) => self.mode_walk = s != "jump",
            _ => self.mode_walk = true,
        }
        self.walk_table_speed = param_f32(params, "smg_walk_table_speed", 13.0);
        self.inertia_stop = param_f32(params, "smg_inertia_stop", 0.94);
        self.inertia_max = param_f32(params, "smg_inertia_max", 0.9);
        self.inertia_rest_stop = param_f32(params, "smg_inertia_rest_stop", 0.85);
        self.inertia_jump_finish = param_f32(params, "smg_inertia_jump_finish", 0.8);
        self.ice_mode = param_bool(params, "smg_ice", false);
        self.inertia_ice_stop = param_f32(params, "smg_inertia_ice_stop", 0.985);
        self.inertia_ice_max = param_f32(params, "smg_inertia_ice_max", 0.995);
        self.inertia_ice_rest = param_f32(params, "smg_inertia_ice_rest", 0.992);
        self.slip_mode = param_bool(params, "smg_slip", false);
        self.inertia_slip_stop = param_f32(params, "smg_inertia_slip_stop", 0.98);
        self.inertia_slip_max = param_f32(params, "smg_inertia_slip_max", 0.99);
        self.inertia_slip_rest = param_f32(params, "smg_inertia_slip_rest", 0.98);
        self.jump_v0 = param_f32(params, "smg_jump_v0", 22.0);
        self.jump_gravity = param_f32(params, "smg_jump_gravity", 1.8);
        self.jump_hold_scale = param_f32(params, "smg_jump_hold_scale", 0.5);
        self.terminal_velocity = param_f32(params, "smg_terminal_velocity", 35.0);
        self.jump_front_speed = param_f32(params, "smg_jump_front_speed", 12.5);
        self.turn_to_stick = param_bool(params, "smg_turn_to_stick", false);
        self.air_control = param_bool(params, "smg_air_control", false);
        match params.get("smg_walk_speed_param") {
            Some(ParamValue::Str(s)) => self.walk_speed_param = s.clone(),
            _ => self.walk_speed_param = "walk.speed".to_string(),
        }
    }

    fn decide_target_index(stick_mag: f32) -> usize {
        let mut i = 0;
        while i < 7 && stick_mag >= SPEED_TABLE_A[i] {
            i += 1;
        }
        i.min(7)
    }
}

impl Default for SmgPhysics {
    fn default() -> Self {
        Self::new()
    }
}

fn write_f32(params: &mut HashMap<String, crate::model::ParamValue>, name: &str, v: f32) {
    params.insert(name.to_string(), crate::model::ParamValue::Float(v as f64));
}

impl StateLogic for SmgPhysics {
    fn on_enter(&mut self, ctx: &mut StateCtx) {
        self.load_params(ctx.params);

        if self.mode_walk {
            // Keep walk speed across walk/wait (harness keeps mWalkSpeed).
            self.walk_speed = param_f32(ctx.params, &self.walk_speed_param, 0.0);
            // Entry tick delta: computed in on_tick below.
        } else {
            // Jump entry: implement chaining logic (Mario::tryJump).
            // Use blackboard for jump_type and land_timer (shared across state instances).
            let ws = param_f32(ctx.params, &self.walk_speed_param, 0.0);
            
            // Read previous jump type and land timer from blackboard
            let prev_type = param_f32(ctx.params, "smg_jump_type", 0.0) as u32;
            let land_t = param_f32(ctx.params, "smg_land_timer", 999.0) as u32;
            
            // Chaining: if land_timer <= 7, chain to next type
            let new_type = if land_t > JUMP_CONNECT_TIME {
                0  // Single
            } else {
                // Chain: increment type (0->1->2->0)
                (prev_type + 1) % 3
            };
            // Check for type override (for testing specific jumps like spin, squat)
            // If smg_jump_type_override is set (>=0), use it directly instead of chaining
            let override_type = param_f32(ctx.params, "smg_jump_type_override", -1.0) as i32;
            let final_type = if override_type >= 0 {
                override_type as u32
            } else {
                // Normal chaining logic
                let new_type = if land_t > JUMP_CONNECT_TIME {
                    0  // Single
                } else {
                    // Chain: increment type (0->1->2->0)
                    (prev_type + 1) % 3
                };
                // Triple requires walkSpeed >= 0.6
                if new_type == 2 && ws < JUMP_CONNECT_SPEED {
                    0
                } else {
                    new_type
                }
            };
            self.jump_type = final_type;
            write_f32(ctx.params, "smg_jump_type", final_type as f32);

            
            // Set v0 and gravity from tables
            // For squat jump (type 5), use special horizontal speed
            let v0 = JUMP_HEIGHTS[final_type as usize];
            self.jump_gravity = JUMP_GRAVITIES[final_type as usize];
            // Squat jump has higher horizontal speed (16.5 vs 12.5)
            let hspeed = if final_type == 5 {
                16.5  // mSquatJumpFrontSpeed
            } else {
                self.jump_front_speed
            };
            
            // JumpVec = facing * (walkSpeed * frontSpeed) + up * v0.
            // Allow behavior to override facing via smg_facing_yaw param (for tests).
            let yaw_deg = param_f32(ctx.params, "smg_facing_yaw", *ctx.facing_yaw);
            let yr = yaw_deg.to_radians();
            let facing = Vec3::new(yr.sin(), 0.0, yr.cos());
            self.jump_vec = facing * (ws * hspeed);
            self.jump_vec.y = v0;
            smg_dbg!("SMG_DBG on_enter frame={}: ws={:.4} hspeed={:.2} v0={:.2} facing=({:.3},{:.3},{:.3}) jump_vec=({:.2},{:.2},{:.2})",
                ctx.frame, ws, hspeed, v0, facing.x, facing.y, facing.z,
                self.jump_vec.x, self.jump_vec.y, self.jump_vec.z);
            self.jump_airborne = false;
            self.jump_entered = true;
            self.jump_y = 0.0;
            write_f32(ctx.params, "smg_land_timer", 0.0);  // Reset after check
            write_f32(ctx.params, "smg_landed", 0.0);
            // Entry tick: no delta (matches harness: state changes on the
            // trigger tick, physics runs from the next tick).
        }
    }

    fn on_tick(&mut self, ctx: &mut StateCtx) {

        if self.mode_walk {
            // decideWalkSpeed: stick magnitude -> target index.
            // (Decomp: decideWalkSpeed runs before mainMoveGround.)
            let stick_mag = (ctx.stick[0] * ctx.stick[0] + ctx.stick[1] * ctx.stick[1]).sqrt().min(1.0);
            let idx = Self::decide_target_index(stick_mag);
            let target = WALK_TARGET_TABLE[idx];

            // Turn toward the stick (MarioMove.cpp turn block, transcribed).
            // Gated by `smg_turn_to_stick` (default false): the differential
            // fixtures encode the harness's turn-less walkTick (e.g.
            // wall_jump presets facing=90 while holding stick +Z), so the
            // turn is opt-in for playable movesets. The decomp rotates
            // mFrontVec toward the stick's world direction by at most
            // turnAngleSpeed rad/tick
            // (vecBlendSphere(mFrontVec, target, clamp01(turnAngleSpeed/diff))).
            // Rate selection: mTurnAngleSpeed (0.9) below mFastTurnSpeed (0.1),
            // mTurnAngleSpeed2 (0.15) above it, mTurnAngleSpeedSlowWalk (0.04)
            // when the stick target index < 5.
            // SIMPLIFICATIONS: no weak-turn ramp (_3D4), no spin-turn
            // (_10._C) path, no tornado/bee variants.
            if self.turn_to_stick && stick_mag > 1e-3 {
                let cur_deg = param_f32(ctx.params, "smg_facing_yaw", *ctx.facing_yaw);
                let tgt_rad = ctx.stick_world.x.atan2(ctx.stick_world.z);
                let rate = if self.walk_speed > 0.1 {
                    if idx < 5 { 0.04 } else { 0.15 }
                } else {
                    0.9
                };
                let mut diff = tgt_rad - cur_deg.to_radians();
                while diff > PI { diff -= 2.0 * PI; }
                while diff < -PI { diff += 2.0 * PI; }
                let new_deg = (cur_deg.to_radians() + diff.clamp(-rate, rate)).to_degrees();
                *ctx.facing_yaw = new_deg;
                // Keep a behavior-set facing override in sync, else it would
                // shadow the turn every tick.
                if ctx.params.contains_key("smg_facing_yaw") {
                    write_f32(ctx.params, "smg_facing_yaw", new_deg);
                }
            }

            // jump_will_fire: when ff_jump is pressed this tick, the
            // Ground->Jump transition fires and the decomp runs NEITHER
            // mainMoveGround NOR updateWalkSpeed (tryJump preempts both).
            // landTimer still ticks (the harness increments it unconditionally
            // at the end of every tick()).
            let jump_will_fire = ctx.input.just_pressed.contains("ff_jump");

            // mainMove core FIRST (decomp order: mainMoveGround runs BEFORE
            // updateWalkSpeed, using the current walkSpeed; walkSpeed starts
            // at 0 so tick 0 naturally moves 0).
            if jump_will_fire {
                *ctx.delta = Vec3::new(0.0, 0.0, 0.0);
            } else {
                let yaw_deg = param_f32(ctx.params, "smg_facing_yaw", *ctx.facing_yaw);
                let yr = yaw_deg.to_radians();
                let facing = Vec3::new(yr.sin(), 0.0, yr.cos());
                *ctx.delta = facing * (self.walk_table_speed * self.walk_speed * UNIT_TO_M);
            }

            // Harness increments landTimer every tick in tick(), unconditionally.
            // Do the same for one-to-one matching (capped at 10000).
            let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
            if lt < 10000.0 {
                write_f32(ctx.params, "smg_land_timer", lt + 1.0);
            }

            if jump_will_fire {
                return;
            }

            // decideInertia (MarioMove.cpp), verbatim.
            // Ice: blend uses TARGET speed (not current), per decideInertiaOnIce.
            // Standard: blend uses current walkSpeed; target==0 uses rest-stop.
            let w = self.walk_speed;
            let inertia = if self.slip_mode {
                if target == 0.0 {
                    self.inertia_slip_rest
                } else {
                    (1.0 - w) * self.inertia_slip_stop + w * self.inertia_slip_max
                }
            } else if self.ice_mode {
                let s = target.min(1.0);
                if target == 0.0 {
                    self.inertia_ice_rest
                } else {
                    (1.0 - s) * self.inertia_ice_stop + s * self.inertia_ice_max
                }
            } else if target == 0.0 {
                let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
                if lt < 30.0 {
                    self.inertia_jump_finish
                } else {
                    self.inertia_rest_stop
                }
            } else {
                (1.0 - w) * self.inertia_stop + w * self.inertia_max
            };
            // updateWalkSpeed core (decomp: after mainMoveGround).
            self.walk_speed = w * inertia + target * (1.0 - inertia);
            write_f32(ctx.params, &self.walk_speed_param, self.walk_speed);
        } else {
            // In-place chain (approved redesign 2026-11-04): the chained jump
            // was armed on the landing tick. The decomp's tryJump frame applies
            // NO movement, so output zero here; physics starts next tick.
            if self.chain_pending {
                self.chain_pending = false;
                *ctx.delta = Vec3::new(0.0, 0.0, 0.0);
                // landTimer still ticks (harness increments unconditionally).
                let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
                if lt < 10000.0 {
                    write_f32(ctx.params, "smg_land_timer", lt + 1.0);
                }
                return;
            }
            // Jump mode: check for spin jump (B button in air)
            // Mario::trySpinJump: if vy < 12.0, set vy = 12.0.
            // Decomp (states.cpp): the trigger frame sets spin/vy but SKIPS
            // procJump() entirely — no position update, no gravity. Mirror
            // with zero delta + early return.
            if ctx.input.just_pressed.contains("ff_attack") && !self.pound_active && !self.wall_sliding {
                if self.jump_vec.y < 12.0 {
                    self.jump_vec.y = 12.0;  // mSpinJumpHeight
                }
                write_f32(ctx.params, "smg_spin_active", 1.0);
                *ctx.delta = Vec3::new(0.0, 0.0, 0.0);
                // landTimer still ticks (harness increments unconditionally).
                let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
                if lt < 10000.0 {
                    write_f32(ctx.params, "smg_land_timer", lt + 1.0);
                }
                return;
            }
            // Reset spin flag on landing (handled via smg_landed)
            
            // Jump mode: check for wall slide
            // If in air and touching wall, enter wall slide
            smg_dbg!("SMG_DBG wall check: floor={} wall={} pound={} sliding={}",
                ctx.contact.floor, ctx.contact.wall, self.pound_active, self.wall_sliding);
            // Wall slide: recomputed every tick like the decomp (physics.cpp:
            // wallSlide is true only while the wall condition holds, else
            // false). NOT a sticky latch — a latch wedges on after the wall
            // jump if contact goes stale (wall_jump RC1).
            let should_slide = !ctx.contact.floor
                && ctx.contact.wall
                && !self.pound_active
                && !self.just_wall_jumped;
            if should_slide && !self.wall_sliding {
                smg_dbg!("SMG_DBG wall: ACTIVATED sliding");
            }
            self.wall_sliding = should_slide;
            // The wall-jump guard lasts one tick (we're still at the wall on
            // the tick after the press since the press tick had zero delta;
            // by the tick after that we've moved away).
            self.just_wall_jumped = false;
            
            // Wall slide physics: slide down at 14 u/f (mWallDropSpeedNormal)
            // Skip on transition tick (just_transitioned handled below, but wall
            // code runs before that check - guard here to avoid corrupting jump_vec)
            if self.wall_sliding {
                smg_dbg!("SMG_DBG wall: check jump, just_pressed={:?} just_trans={}",
                    ctx.input.just_pressed, ctx.just_transitioned);
                // Wall jump: decomp sets jumpVec = wallNormal*13 + up*30 but
                // applies NO movement on the trigger tick (tryWallJump sets
                // jumpVec only; movement happens next frame via procJump).
                // Mirror with zero delta; the impulse applies next tick via
                // normal jump physics.
                if ctx.input.just_pressed.contains("ff_jump") && !ctx.just_transitioned {
                    smg_dbg!("SMG_DBG wall: JUMP TRIGGERED!");
                    self.jump_vec = Vec3::new(
                        ctx.contact.wall_normal.x * 13.0,  // mWallJumpPowerXZ
                        30.0,  // mWallJumpPowerY
                        ctx.contact.wall_normal.z * 13.0,
                    );
                    // Decomp tryWallJump sets jumpType=JT_Wall, so gravity is
                    // mGravityJumping[JT_Wall]=0.95 (not 1.8). Oracle vy falls
                    // 0.475/tick = 0.95*0.5 (rising+held).
                    self.jump_gravity = 0.95;
                    self.wall_sliding = false;
                    // Block slide re-activation next tick (we're still at the
                    // wall; the decomp is in "jump" state, not "wallslide").
                    self.just_wall_jumped = true;
                    *ctx.delta = Vec3::new(0.0, 0.0, 0.0);
                    smg_dbg!("SMG_DBG wall: jump triggered, zero delta (impulse next tick)");
                    // landTimer still ticks (harness increments unconditionally).
                    let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
                    if lt < 10000.0 {
                        write_f32(ctx.params, "smg_land_timer", lt + 1.0);
                    }
                    return;
                } else {
                    *ctx.delta = Vec3::new(0.0, -14.0 * UNIT_TO_M, 0.0);
                    self.jump_y += -14.0;
                    smg_dbg!("SMG_DBG wall: slide delta=({:.4},{:.4},{:.4}) jump_y={:.1}",
                        ctx.delta.x, ctx.delta.y, ctx.delta.z, self.jump_y);
                    // Skip normal physics while sliding
                }
            } else {
            // Jump mode: check for ground pound activation
            // StateCtx only has held. We detect pound via ff_pound in held
            // on the entry tick after a Z press. Simpler: check if ff_pound
            // was just pressed by looking at the transition.
            // For now, activate pound if ff_pound is held and we're airborne.
            // The harness triggers pound via trgZ which sets the button.
            
            // Ground pound: if ff_pound pressed while airborne, activate
            // We use a simple heuristic: if pound button is held and y > 0,
            // and not already pounding, activate.
            // Actually, the proper way is to check just_pressed, but StateCtx
            // doesn't expose it directly. We'll use the fact that the behavior
            // can have a separate Pound state, but for simplicity, we do it here.
            
            // For the differential test, the Z press is a single frame.
            // We'll detect it via the blackboard or a flag.
            // Simplest: if ff_pound in held and jump_y > 10 (in air), activate.
            if !self.pound_active && ctx.input.just_pressed.contains("ff_pound") && self.jump_y > 10.0 {
                self.pound_active = true;
                // Kill horizontal velocity (harness: zero horizontal)
                self.jump_vec.x = 0.0;
                self.jump_vec.z = 0.0;
                self.jump_vec.y = 0.0;  // Start pound from zero vertical
            }
            
            // Pound physics: accelerate down at 12, clamp at 150
            if self.pound_active {
                // Hip-drop: mGravityHipDrop=12, mLimitSpeedHipDrop=150
                self.jump_y += self.jump_vec.y;
                if self.jump_y <= 0.0 && self.jump_vec.y < 0.0 {
                    // Landed: clamp
                    let y_before = self.jump_y - self.jump_vec.y;
                    let clamped_dy = -y_before;
                    *ctx.delta = Vec3::new(0.0, clamped_dy * UNIT_TO_M, 0.0);
                    // doLanding handoff (also runs on pound landings in the
                    // decomp): walkSpeed = hSpeed / mWalkSpeed (0 here — the
                    // pound kills horizontal velocity at activation).
                    let hspeed = (self.jump_vec.x * self.jump_vec.x
                        + self.jump_vec.z * self.jump_vec.z)
                        .sqrt()
                        / self.walk_table_speed;
                    self.walk_speed = hspeed;
                    write_f32(ctx.params, &self.walk_speed_param, hspeed);
                    self.jump_y = 0.0;
                    self.jump_vec.y = 0.0;
                    self.pound_active = false;
                    self.jump_airborne = false;
                    write_f32(ctx.params, "smg_landed", 1.0);
                } else {
                    *ctx.delta = Vec3::new(0.0, self.jump_vec.y * UNIT_TO_M, 0.0);
                    self.jump_vec.y -= 12.0;  // mGravityHipDrop
                    if self.jump_vec.y < -150.0 {  // mLimitSpeedHipDrop
                        self.jump_vec.y = -150.0;
                    }
                }
                // Skip normal jump physics
            } else {
            // Normal jump physics (procJump core).
            // Air control (MarioJump.cpp doAirWalk; the harness's simplified
            // form). Gated by `smg_air_control` (default false): the
            // differential oracles come from the harness, whose jumpTick
            // never calls doAirWalk, so air control is opt-in for playable
            // movesets. Drift the horizontal jumpVec toward the stick's world
            // direction: want = cur + mAirWalkBonus*0.1 (3.0*0.1), capped at
            // mMaxJumpSpeed (32.0); h' = moveDir*want*0.1 + h*0.9.
            // SIMPLIFICATION: no front-reduction curve when pulling back
            // (mJumpFrontReduction), no animation/state guards.
            if self.air_control && !ctx.contact.floor {
                let (swx, swz) = (ctx.stick_world.x, ctx.stick_world.z);
                let smag = (swx * swx + swz * swz).sqrt();
                if smag > 1e-3 {
                    let (mx, mz) = (swx / smag, swz / smag);
                    let (hx, hz) = (self.jump_vec.x, self.jump_vec.z);
                    let cur = (hx * hx + hz * hz).sqrt();
                    let want = (cur + 3.0 * 0.1).min(32.0);
                    self.jump_vec.x = mx * want * 0.1 + hx * 0.9;
                    self.jump_vec.z = mz * want * 0.1 + hz * 0.9;
                }
            }
            // Variable height: holding jump while rising halves gravity.
            let rising = self.jump_vec.y > 0.0;
            let jump_held = param_bool(ctx.params, "smg_jump_held", false)
                || ctx.input.held.contains("ff_jump")
                || ctx.input.held.contains("ff_jump_held");
            let scale = if rising && jump_held {
                self.jump_hold_scale
            } else {
                1.0
            };
            // Gravity: the decomp NEVER changes gravity for a spin. procJump()
            // uses mGravityJumping[jumpType], and the spin handler does not
            // touch jumpType — mSpinJumpGravity (0.25) is dead in the decomp
            // (trySpinJump has zero call sites). Verified by oracle: vy falls
            // 0.90/tick while rising+held, not 0.25.
            let gravity = self.jump_gravity * scale;
            // procJump order: pos += jumpVec THEN jumpVec += gravity.
            // (Matches the harness: delta uses current v, then v is updated.)
            // NOTE: Do NOT skip the entry tick. The ff diff aligns FF tick k
            // Skip physics on the transition tick.
            // The core sets ctx.just_transitioned=true when enter_state() fires.
            // This matches the decomp where tryJump() changes state before
            // mainMoveGround() runs (no physics on transition tick).
            // Using the explicit flag is more reliable than frame==0.
            // TEST CONFIG (user 2026-11-04): just_transitioned skip DISABLED
            // via `if false` to isolate whether the 5.06cm comes from the
            // transition tick or the jump trajectory itself.
            if false && ctx.just_transitioned {
                smg_dbg!("SMG_DBG: just_transitioned, skipping physics");
                *ctx.delta = Vec3::new(0.0, 0.0, 0.0);
            } else {
            // Track Y in SMG units to detect landing without relying on
            // the 1-tick-stale contact. Matches harness ground clamp.
            self.jump_y += self.jump_vec.y;
            if self.jump_y <= 0.0 && self.jump_vec.y < 0.0 {
                // Landed: clamp to ground (harness sets pos.y=0).
                // Output delta that brings y to exactly 0.
                let y_before = self.jump_y - self.jump_vec.y;
                let clamped_dy = -y_before; // brings y to 0
                // doLanding handoff (MarioJump.cpp, verbatim): the landing
                // preserves horizontal velocity into walkSpeed, so the first
                // walk tick after landing moves at the jump's horizontal
                // speed — NOT the pre-jump walkSpeed.
                let hspeed = (self.jump_vec.x * self.jump_vec.x
                    + self.jump_vec.z * self.jump_vec.z)
                    .sqrt()
                    / self.walk_table_speed;
                self.walk_speed = hspeed;
                write_f32(ctx.params, &self.walk_speed_param, hspeed);
                *ctx.delta = Vec3::new(
                    self.jump_vec.x * UNIT_TO_M,
                    clamped_dy * UNIT_TO_M,
                    self.jump_vec.z * UNIT_TO_M,
                );
                self.jump_y = 0.0;
                self.jump_vec.y = 0.0;
                self.jump_airborne = false;
                // Reset spin flags on landing
                write_f32(ctx.params, "smg_spin_done", 0.0);
                write_f32(ctx.params, "smg_spin_active", 0.0);
                // Clear wall slide on landing
                self.wall_sliding = false;
                // Harness resets landTimer=0 on landing (doLanding). Do the same
                // for one-to-one chaining (land_t <= 7 chains to next type).
                write_f32(ctx.params, "smg_land_timer", 0.0);
                // In-place triple chaining (approved redesign 2026-11-04): if
                // jump is pressed on the landing tick, chain directly to the
                // next jump type WITHOUT transitioning through Ground. The
                // instance stays alive, so jump_type persists (no blackboard
                // sync issue). The test runner shifts the oracle's N+1 press
                // to tick N for FF. Output is the LANDING delta above; the new
                // jumpVec takes effect from tick N+2 (tick N+1 outputs zero via
                // chain_pending, matching the decomp's no-movement tryJump
                // frame).
                if ctx.input.just_pressed.contains("ff_jump") {
                    let land_t = param_f32(ctx.params, "smg_land_timer", 999.0) as u32;
                    let prev_type = self.jump_type;
                    let chained = if land_t > JUMP_CONNECT_TIME {
                        0
                    } else {
                        (prev_type + 1) % 3
                    };
                    // Triple requires walkSpeed >= 0.6 (mJumpConnectSpeed).
                    // walk_speed here is the handoff value (set above).
                    let chained = if chained == 2 && self.walk_speed < JUMP_CONNECT_SPEED {
                        0
                    } else {
                        chained
                    };
                    // Respect the test override, like on_enter.
                    let override_type =
                        param_f32(ctx.params, "smg_jump_type_override", -1.0) as i32;
                    let final_type = if override_type >= 0 {
                        override_type as u32
                    } else {
                        chained
                    };
                    self.jump_type = final_type;
                    write_f32(ctx.params, "smg_jump_type", final_type as f32);
                    let v0 = JUMP_HEIGHTS[final_type as usize];
                    self.jump_gravity = JUMP_GRAVITIES[final_type as usize];
                    // jumpVec = facing * (walkSpeed * frontSpeed) + up * v0
                    // (decomp tryJump). Facing override honored like on_enter.
                    let yaw_deg = param_f32(ctx.params, "smg_facing_yaw", *ctx.facing_yaw);
                    let yr = yaw_deg.to_radians();
                    let facing = Vec3::new(yr.sin(), 0.0, yr.cos());
                    self.jump_vec = facing * (self.walk_speed * self.jump_front_speed);
                    self.jump_vec.y = v0;
                    self.jump_y = 0.0;
                    self.chain_pending = true;
                    smg_dbg!("SMG_DBG: in-place chain frame={} prev={} new={} v0={:.1} ws={:.4}",
                        ctx.frame, prev_type, final_type, v0, self.walk_speed);
                    // Do NOT set smg_landed — stay in Jump.
                } else {
                    write_f32(ctx.params, "smg_landed", 1.0);
                }
            } else {
                let dx = self.jump_vec.x * UNIT_TO_M;
                let dy = self.jump_vec.y * UNIT_TO_M;
                let dz = self.jump_vec.z * UNIT_TO_M;
                smg_dbg!("SMG_DBG: physics frame={} jump_vec=({:.2},{:.2},{:.2}) delta=({:.4},{:.4},{:.4}) jump_y={:.2}",
                    ctx.frame, self.jump_vec.x, self.jump_vec.y, self.jump_vec.z, dx, dy, dz, self.jump_y);
                *ctx.delta = self.jump_vec * UNIT_TO_M;
                self.jump_vec.y -= gravity;
                if self.jump_vec.y < -self.terminal_velocity {
                    self.jump_vec.y = -self.terminal_velocity;
                }
            }
            }  // close pound if/else
            }  // close wall_sliding if/else
            }  // close jump_entered else

            // Harness increments landTimer every tick in tick(). Do the same
            // for one-to-one matching (capped at 10000).
            let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
            if lt < 10000.0 {
                write_f32(ctx.params, "smg_land_timer", lt + 1.0);
            }

            // Mark airborne when leaving ground (for transition guards).
            if !ctx.contact.floor {
                self.jump_airborne = true;
            }
        }
    }

    fn on_exit(&mut self, _ctx: &mut StateCtx) {}
}
