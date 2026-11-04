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
            let yr = (*ctx.facing_yaw).to_radians();
            let facing = Vec3::new(yr.sin(), 0.0, yr.cos());
            self.jump_vec = facing * (ws * hspeed);
            self.jump_vec.y = v0;
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
            // Note: The core tick.rs now skips on_tick physics when a behavior
            // transition will fire (via would_behavior_transition check in Phase A).
            // This matches the decomp's transition-before-physics ordering.
            let stick_mag = (ctx.stick[0] * ctx.stick[0] + ctx.stick[1] * ctx.stick[1]).sqrt().min(1.0);
            let idx = Self::decide_target_index(stick_mag);
            let target = WALK_TARGET_TABLE[idx];

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
            // Harness increments landTimer every tick in tick(), unconditionally.
            // Do the same for one-to-one matching (capped at 10000).
            let lt = param_f32(ctx.params, "smg_land_timer", 999.0);
            if lt < 10000.0 {
                write_f32(ctx.params, "smg_land_timer", lt + 1.0);
            }

            // updateWalkSpeed core.
            self.walk_speed = w * inertia + target * (1.0 - inertia);
            write_f32(ctx.params, &self.walk_speed_param, self.walk_speed);

            // mainMove core: delta = facing * (table_speed * walk_speed).
            let yr = (*ctx.facing_yaw).to_radians();
            let facing = Vec3::new(yr.sin(), 0.0, yr.cos());
            *ctx.delta = facing * (self.walk_table_speed * self.walk_speed * UNIT_TO_M);
        } else {
            // Jump mode: check for spin jump (B button in air)
            // Mario::trySpinJump: if vy < 12.0, set vy = 12.0
            if ctx.input.held.contains("ff_attack") && !self.pound_active && !self.wall_sliding {
                // Spin jump boost - only apply once per press (check via a flag)
                // For simplicity, apply if current vy < 12.0
                // Note: proper implementation needs just_pressed detection
                // We'll use a param to track if spin was already applied
                let spin_done = param_bool(ctx.params, "smg_spin_done", false);
                if !spin_done && self.jump_vec.y < 12.0 {
                    self.jump_vec.y = 12.0;  // mSpinJumpHeight
                    write_f32(ctx.params, "smg_spin_done", 1.0);
                    // Spin uses low gravity (0.25) - set a flag
                    write_f32(ctx.params, "smg_spin_active", 1.0);
                }
            }
            // Reset spin flag on landing (handled via smg_landed)
            
            // Jump mode: check for wall slide
            // If in air and touching wall, enter wall slide
            if !ctx.contact.floor && ctx.contact.wall && !self.pound_active {
                self.wall_sliding = true;
            } else if !ctx.contact.wall {
                self.wall_sliding = false;
            }
            
            // Wall slide physics: slide down at 14 u/f (mWallDropSpeedNormal)
            if self.wall_sliding {
                // Wall jump requires just_pressed detection which StateCtx doesn't have.
                // TODO: Implement proper wall jump velocity on press via behavior transition.
                // For now, slide only.
                *ctx.delta = Vec3::new(0.0, -14.0 * UNIT_TO_M, 0.0);
                self.jump_y += -14.0;
                // Skip normal physics while sliding
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
            if !self.pound_active && ctx.input.held.contains("ff_pound") && self.jump_y > 10.0 {
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
            // Spin jump uses low gravity (0.25) for floaty effect
            let spin_active = param_bool(ctx.params, "smg_spin_active", false);
            let gravity = if spin_active {
                0.25  // mSpinJumpGravity
            } else {
                self.jump_gravity * scale
            };
            // procJump order: pos += jumpVec THEN jumpVec += gravity.
            // (Matches the harness: delta uses current v, then v is updated.)
            // NOTE: Do NOT skip the entry tick. The ff diff aligns FF tick k
            // Skip physics on the transition tick.
            // The core sets ctx.just_transitioned=true when enter_state() fires.
            // This matches the decomp where tryJump() changes state before
            // mainMoveGround() runs (no physics on transition tick).
            // Using the explicit flag is more reliable than frame==0.
            if ctx.just_transitioned {
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
                *ctx.delta = Vec3::new(
                    self.jump_vec.x * UNIT_TO_M,
                    clamped_dy * UNIT_TO_M,
                    self.jump_vec.z * UNIT_TO_M,
                );
                self.jump_y = 0.0;
                self.jump_vec.y = 0.0;
                self.jump_airborne = false;
                write_f32(ctx.params, "smg_landed", 1.0);
                // Reset spin flags on landing
                write_f32(ctx.params, "smg_spin_done", 0.0);
                write_f32(ctx.params, "smg_spin_active", 0.0);
                // Harness resets landTimer=0 on landing (doLanding). Do the same
                // for one-to-one chaining (land_t <= 7 chains to next type).
                write_f32(ctx.params, "smg_land_timer", 0.0);
            } else {
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
