//! FrameForge GDExtension — `BehaviorPlayer` node wrapping `frameforge-core`.
//!
//! The core stays kinematic (per-tick deltas only); `move_and_slide` and
//! collision stay on the Godot side. Tick order mirrors `behavior_player.gd`:
//! sample input → core.tick_delta → velocity → move_and_slide →
//! core.tick_contact → drain signal logs.

use godot::classes::{CharacterBody3D, FileAccess, ICharacterBody3D, Input};
use godot::prelude::*;

use frameforge_core::input::TickInput;
use frameforge_core::tick::{ContactState, Runtime};
use frameforge_core::vec3::Vec3 as FVec3;
use frameforge_core::{ConditionType, FrameBehavior, ParamValue};

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

struct FrameForgeExt;

#[gdextension]
unsafe impl ExtensionLibrary for FrameForgeExt {}

/// Drop-in character node. Loads a behavior JSON, ticks the core at 60 Hz
/// in `_physics_process`, applies the delta via `move_and_slide`.
#[derive(GodotClass)]
#[class(base = CharacterBody3D)]
pub struct BehaviorPlayer {
    base: Base<CharacterBody3D>,

    core: Option<Runtime>,
    tracked: Vec<String>,
    tick_accum: f64,
    /// For fall.distance probe: accumulates downward distance while airborne.
    fall_accum: f32,
    was_ground: bool,
    /// Inputs for the SMO OnCustom predicates (known issue #7), synced from
    /// the core in sync_smo_probes() before each tick. The predicate
    /// closures registered in load_behavior() read through this cell.
    smo_preds: Rc<RefCell<PredInputs>>,

    #[var]
    behavior_path: GString,
    #[var]
    auto_step: bool,
    /// Ticks per second for the behavior clock (default 60).
    #[var]
    tick_rate_hz: f32,
    #[var]
    camera_yaw_deg: f32,
}

#[godot_api]
impl BehaviorPlayer {
    #[signal]
    fn state_entered(behavior: GString, machine: GString, state: GString);
    #[signal]
    fn state_exited(behavior: GString, machine: GString, state: GString);
    #[signal]
    fn behavior_changed(old: GString, new: GString);
    #[signal]
    fn event_fired(name: GString);

    /// Load a behavior JSON (res:// or user:// path). Returns success.
    #[func]
    fn load_behavior(&mut self, path: GString) -> bool {
        let text = FileAccess::get_file_as_string(&path);
        if text.is_empty() {
            godot_error!("FrameForge: cannot read behavior file {}", path);
            return false;
        }
        match FrameBehavior::load_json_str(&text.to_string()) {
            Ok(bh) => {
                self.tracked = collect_actions(&bh);
                let mut rt = Runtime::new(bh);
                // SMO OnCustom predicates (known issue #7). Registered for
                // every behavior; harmless when the JSON never names them.
                let preds = Rc::new(RefCell::new(PredInputs::default()));
                for (name, f) in [
                    ("smo.triple_ok", triple_ok as fn(&PredInputs) -> bool),
                    ("smo.double_ok", double_ok as fn(&PredInputs) -> bool),
                    (
                        "smo.pivot_moving_ok",
                        pivot_moving_ok as fn(&PredInputs) -> bool,
                    ),
                ] {
                    let p = preds.clone();
                    rt.register_custom_condition(
                        name,
                        Box::new(move || f(&p.borrow())),
                    );
                }
                self.smo_preds = preds;
                self.core = Some(rt);
                self.behavior_path = path;
                true
            }
            Err(e) => {
                godot_error!("FrameForge: behavior parse failed: {}", e);
                false
            }
        }
    }

    #[func]
    fn set_param(&mut self, name: GString, value: Variant) {
        if let (Some(core), Some(pv)) = (self.core.as_mut(), variant_to_param(&value)) {
            core.set_param(&name.to_string(), pv);
        }
    }

    #[func]
    fn get_param(&self, name: GString) -> Variant {
        self.core
            .as_ref()
            .and_then(|c| c.get_param(&name.to_string()))
            .map(param_to_variant)
            .unwrap_or(Variant::nil())
    }

    #[func]
    fn emit_event(&mut self, name: GString) {
        if let Some(core) = self.core.as_mut() {
            core.emit_event(&name.to_string());
        }
    }

    #[func]
    fn current_state_name(&self, machine: GString) -> GString {
        self.core
            .as_ref()
            .and_then(|c| {
                c.track_states()
                    .into_iter()
                    .find(|(m, _, _)| m == &machine.to_string())
                    .map(|(_, s, _)| s)
            })
            .map(|s| GString::from(s.as_str()))
            .unwrap_or(GString::from("<none>"))
    }

    #[func]
    fn tick_count(&self) -> i64 {
        self.core
            .as_ref()
            .map(|c| c.tick_count() as i64)
            .unwrap_or(0)
    }

    /// Force a state change (bridge-driven). For external events like damage
    /// that bypass normal transition rows. Returns success.
    #[func]
    fn force_state(&mut self, machine: GString, state: GString) -> bool {
        if let Some(core) = self.core.as_mut() {
            core.force_state(&machine.to_string(), &state.to_string())
        } else {
            false
        }
    }

    /// Set the analog stick (x right, y up/forward). Length clamped to 1.
    /// Call before tick(), or use sync_smo_probes() which reads from input.
    #[func]
    fn set_stick(&mut self, x: f32, y: f32) {
        if let Some(core) = self.core.as_mut() {
            core.set_stick(x, y);
        }
    }

    /// Sync SMO bridge probes from CharacterBody3D state. Call before tick().
    /// Sets: contact.ground, contact.wall, motion.hspeed, fall.distance,
    /// stick.up, stick.down. Also syncs the inputs of the SMO OnCustom
    /// predicates (smo.double_ok / smo.triple_ok / smo.pivot_moving_ok).
    /// Water/hang/damage/pit/surface probes must be set via set_param() by
    /// the game (they need game-specific queries).
    #[func]
    fn sync_smo_probes(&mut self, stick_x: f32, stick_y: f32) {
        // Read body state first (immutable borrow), then core (mutable).
        // Note: contact.ground uses is_on_floor() (1 tick stale). For tighter
        // landings, the game can override via set_param("contact.ground")
        // using test_move prediction. See known issues #5.
        let (on_floor, on_wall, vel) = {
            let body = self.base();
            (
                body.is_on_floor(),
                body.is_on_wall(),
                body.get_velocity(),
            )
        };
        let Some(core) = self.core.as_mut() else {
            return;
        };
        // Stick.
        core.set_stick(stick_x, stick_y);
        core.set_param("stick.up", ParamValue::Bool(stick_y >= 0.5));
        core.set_param("stick.down", ParamValue::Bool(stick_y <= -0.5));

        // Contact.
        core.set_param("contact.ground", ParamValue::Bool(on_floor));
        core.set_param("contact.wall", ParamValue::Bool(on_wall));

        // Motion.
        let hspeed = (vel.x * vel.x + vel.z * vel.z).sqrt();
        // hspeed is in units/sec; core expects units/frame at 60Hz.
        core.set_param("motion.hspeed", ParamValue::Float((hspeed / 60.0) as f64));

        // Fall distance: accumulates while airborne, resets on landing
        // (but persists through the landing tick so land_sel can read it).
        if on_floor && self.was_ground {
            self.fall_accum = 0.0;
        } else if !on_floor {
            let dy = vel.y / 60.0;
            if dy < 0.0 {
                self.fall_accum += -dy;
            }
        }
        self.was_ground = on_floor;
        core.set_param("fall.distance", ParamValue::Float(self.fall_accum as f64));

        // SMO predicate inputs (known issue #7): mirror the test Rig's
        // per-tick sync. Chain bookkeeping comes from the behavior's own
        // params; velocity/facing from the Nerves track; the stick is fed
        // in world frame, using the core's camera-relative mapping (the
        // Rig runs at camera yaw 0, where world frame == raw stick).
        {
            let mut p = self.smo_preds.borrow_mut();
            p.chain_state = match core.get_param("chain.state") {
                Some(ParamValue::Int(v)) => *v,
                _ => 0,
            };
            p.ground_window = match core.get_param("chain.ground_window") {
                Some(ParamValue::Int(v)) => *v,
                _ => 0,
            };
            p.air_from = match core.get_param("air.from") {
                Some(ParamValue::Str(s)) => s.clone(),
                _ => String::new(),
            };
            let v = core.track_velocity("Nerves");
            p.vel = [v.x, v.y, v.z];
            p.facing = core.track_facing_yaw("Nerves");
            // Same clamp as Runtime::set_stick, then rotate by camera yaw:
            // world = right * sx + fwd * (-sy) with right = (cos, -sin),
            // fwd = (-sin, -cos) in (x, z) — cf. core's stick_world_dir.
            let len = (stick_x * stick_x + stick_y * stick_y).sqrt();
            let (sx, sy) = if len > 1.0 {
                (stick_x / len, stick_y / len)
            } else {
                (stick_x, stick_y)
            };
            let (s, c) = self.camera_yaw_deg.to_radians().sin_cos();
            p.stick = [c * sx + s * sy, -s * sx + c * sy];
        }
    }

    /// Manual tick (when auto_step is off). Returns the applied delta.
    #[func]
    fn tick(&mut self) -> Vector3 {
        if self.core.is_none() {
            return Vector3::ZERO;
        }
        let input = self.sample_input();
        // Sample stick from input actions (assumes standard UI actions).
        let stick = self.sample_stick();
        self.sync_smo_probes(stick.x, stick.y);
        let yaw = self.camera_yaw_deg.to_radians();
        // Phase A: rows + deltas (scoped borrow).
        let d = {
            let core = self.core.as_mut().unwrap();
            core.camera_yaw = yaw;
            core.tick_delta(&input)
        };
        // Move via Godot physics.
        let vel = Vector3::new(d.x * 60.0, d.y * 60.0, d.z * 60.0);
        {
            let mut body = self.base_mut();
            body.set_velocity(vel);
            body.move_and_slide();
        }
        // Phase B: collision + transitions (scoped borrow).
        let contact = self.read_contact();
        {
            let core = self.core.as_mut().unwrap();
            core.tick_contact(&contact);
        }
        self.drain_signals();
        Vector3::new(d.x, d.y, d.z)
    }

    fn sample_stick(&self) -> Vector2 {
        let input = Input::singleton();
        // Standard Godot UI actions; game can override via set_stick().
        let x = input.get_action_strength(&StringName::from("ui_right"))
            - input.get_action_strength(&StringName::from("ui_left"));
        let y = input.get_action_strength(&StringName::from("ui_up"))
            - input.get_action_strength(&StringName::from("ui_down"));
        Vector2::new(x, y)
    }

    fn sample_input(&self) -> TickInput {
        let input = Input::singleton();
        let mut held = HashSet::new();
        let mut strengths = HashMap::new();
        for a in &self.tracked {
            let an = StringName::from(a.as_str());
            if input.is_action_pressed(&an) {
                held.insert(a.clone());
                strengths.insert(a.clone(), input.get_action_strength(&an));
            }
        }
        TickInput { held, strengths }
    }

    fn read_contact(&self) -> ContactState {
        let body = self.base();
        let mut c = ContactState {
            floor: body.is_on_floor(),
            ceiling: body.is_on_ceiling(),
            wall: body.is_on_wall(),
            ..Default::default()
        };
        if c.floor {
            let n = body.get_floor_normal();
            c.floor_normal = FVec3::new(n.x, n.y, n.z);
            // G-6: velocity of the platform we're standing on.
            let v = body.get_platform_velocity();
            c.floor_velocity = FVec3::new(v.x, v.y, v.z);
        }
        if c.wall {
            let n = body.get_wall_normal();
            c.wall_normal = FVec3::new(n.x, n.y, n.z);
        }
        // G-6: wall/ceiling collider velocities from slide collisions.
        // Matches the collision whose normal aligns with the reported
        // wall/ceiling normal (dot > 0.9); corners pick the dominant one.
        let count = body.get_slide_collision_count();
        for i in 0..count {
            let Some(col) = body.get_slide_collision(i) else {
                continue;
            };
            let n = col.get_normal();
            let v = col.get_collider_velocity();
            let nv = FVec3::new(n.x, n.y, n.z);
            let vv = FVec3::new(v.x, v.y, v.z);
            if c.wall && nv.dot(c.wall_normal) > 0.9 {
                c.wall_velocity = vv;
            } else if c.ceiling && nv.y < -0.9 {
                c.ceiling_velocity = vv;
            }
        }
        c
    }

    fn drain_signals(&mut self) {
        let Some(core) = self.core.as_mut() else {
            return;
        };
        // Emit in signal_log order to preserve exit/enter interleaving.
        let order = std::mem::take(&mut core.signal_log);
        let _entered = std::mem::take(&mut core.entered_log);
        let _exited = std::mem::take(&mut core.exited_log);
        let _changed = std::mem::take(&mut core.behavior_changed_log);
        let events = std::mem::take(&mut core.event_log);
        for entry in order {
            if let Some(rest) = entry.strip_prefix("exit ") {
                let mut parts = rest.splitn(3, '/');
                let (b, m, s) = (
                    parts.next().unwrap_or(""),
                    parts.next().unwrap_or(""),
                    parts.next().unwrap_or(""),
                );
                self.base_mut().emit_signal(
                    "state_exited",
                    &[b.to_variant(), m.to_variant(), s.to_variant()],
                );
            } else if let Some(rest) = entry.strip_prefix("enter ") {
                let mut parts = rest.splitn(3, '/');
                let (b, m, s) = (
                    parts.next().unwrap_or(""),
                    parts.next().unwrap_or(""),
                    parts.next().unwrap_or(""),
                );
                self.base_mut().emit_signal(
                    "state_entered",
                    &[b.to_variant(), m.to_variant(), s.to_variant()],
                );
            } else if let Some(rest) = entry.strip_prefix("behavior ") {
                let mut parts = rest.splitn(2, "->");
                let (o, n) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
                self.base_mut()
                    .emit_signal("behavior_changed", &[o.to_variant(), n.to_variant()]);
            }
        }
        for e in events {
            self.base_mut()
                .emit_signal("event_fired", &[e.to_variant()]);
        }
    }
}

#[godot_api]
impl ICharacterBody3D for BehaviorPlayer {
    fn init(base: Base<CharacterBody3D>) -> Self {
        Self {
            base,
            core: None,
            tracked: Vec::new(),
            behavior_path: GString::new(),
            auto_step: true,
            tick_rate_hz: 60.0,
            tick_accum: 0.0,
            camera_yaw_deg: 0.0,
            fall_accum: 0.0,
            was_ground: false,
            smo_preds: Rc::new(RefCell::new(PredInputs::default())),
        }
    }

    fn ready(&mut self) {
        if !self.behavior_path.is_empty() {
            let path = self.behavior_path.clone();
            self.load_behavior(path);
        }
    }

    fn physics_process(&mut self, delta: f64) {
        if !self.auto_step {
            return;
        }
        self.tick_accum += delta;
        let interval = 1.0 / self.tick_rate_hz.max(1.0) as f64;
        let mut guard = 0;
        while self.tick_accum >= interval && guard < 8 {
            self.tick_accum -= interval;
            guard += 1;
            self.tick();
        }
    }
}

/// Collect action names the core needs sampled: ON_INPUT condition actions
/// plus per-state input_* actions (for strengths).
fn collect_actions(bh: &FrameBehavior) -> Vec<String> {
    let mut seen = HashSet::new();
    for row in &bh.behavior_transitions {
        if row.condition.cond_type == ConditionType::OnInput {
            for a in &row.condition.input_actions {
                seen.insert(a.clone());
            }
        }
    }
    for m in &bh.sub_machines {
        for st in &m.states {
            for row in &st.transitions {
                if row.condition.cond_type == ConditionType::OnInput {
                    for a in &row.condition.input_actions {
                        seen.insert(a.clone());
                    }
                }
            }
            for a in [
                &st.input_left,
                &st.input_right,
                &st.input_forward,
                &st.input_back,
            ] {
                if !a.is_empty() {
                    seen.insert(a.clone());
                }
            }
        }
    }
    let mut v: Vec<String> = seen.into_iter().collect();
    v.sort();
    v
}

fn variant_to_param(v: &Variant) -> Option<ParamValue> {
    if let Ok(f) = v.try_to::<f64>() {
        Some(ParamValue::Float(f))
    } else if let Ok(i) = v.try_to::<i64>() {
        Some(ParamValue::Int(i))
    } else if let Ok(b) = v.try_to::<bool>() {
        Some(ParamValue::Bool(b))
    } else if let Ok(s) = v.try_to::<GString>() {
        Some(ParamValue::Str(s.to_string()))
    } else if let Ok(v3) = v.try_to::<Vector3>() {
        // G-6: spatial params (D9), e.g. `ledgegrab.offset`.
        Some(ParamValue::Vec3([v3.x, v3.y, v3.z]))
    } else {
        None
    }
}

fn param_to_variant(pv: &ParamValue) -> Variant {
    match pv {
        ParamValue::Float(f) => f.to_variant(),
        ParamValue::Int(i) => i.to_variant(),
        ParamValue::Bool(b) => b.to_variant(),
        ParamValue::Str(s) => GString::from(s.as_str()).to_variant(),
        ParamValue::Vec3([x, y, z]) => Vector3::new(*x, *y, *z).to_variant(),
    }
}

// ---------------------------------------------------------------------------
// SMO OnCustom predicates (known issue #7)
//
// Ported verbatim from the reference implementation in
// frameforge-core/tests/smo_p0.rs (the test Rig), so bridge behavior matches
// the anchors exactly. Inputs are synced per tick in sync_smo_probes(); the
// one adaptation is the stick: the Rig feeds the raw stick at camera yaw 0,
// the bridge feeds the world-frame stick (identical at yaw 0).

#[derive(Clone, Default)]
struct PredInputs {
    chain_state: i64,
    ground_window: i64,
    air_from: String,
    vel: [f32; 3],
    facing: f32,
    stick: [f32; 2],
}

fn hspeed(p: &PredInputs) -> f32 {
    (p.vel[0] * p.vel[0] + p.vel[2] * p.vel[2]).sqrt()
}

fn facing_dir(yaw_deg: f32) -> [f32; 2] {
    let r = yaw_deg.to_radians();
    [r.sin(), r.cos()]
}

fn speed_along_facing(p: &PredInputs) -> f32 {
    let f = facing_dir(p.facing);
    p.vel[0] * f[0] + p.vel[2] * f[1]
}

fn vel_facing_angle(p: &PredInputs) -> f32 {
    let hs = hspeed(p);
    if hs < 1e-6 {
        return 0.0;
    }
    let f = facing_dir(p.facing);
    let dot = ((p.vel[0] * f[0] + p.vel[2] * f[1]) / hs).clamp(-1.0, 1.0);
    dot.acos().to_degrees()
}

fn stick_radius(p: &PredInputs) -> f32 {
    (p.stick[0] * p.stick[0] + p.stick[1] * p.stick[1]).sqrt()
}

/// Angle between stick (world x,z = sx,sy at camera yaw 0) and a reference.
fn stick_angle_vs(p: &PredInputs, rx: f32, rz: f32) -> f32 {
    let r = stick_radius(p);
    if r < 1e-6 {
        return 0.0;
    }
    let rl = (rx * rx + rz * rz).sqrt();
    if rl < 1e-6 {
        return 0.0;
    }
    let dot = ((p.stick[0] * rx + p.stick[1] * rz) / (r * rl)).clamp(-1.0, 1.0);
    dot.acos().to_degrees()
}

/// JP-08: triple jump chain intact.
fn triple_ok(p: &PredInputs) -> bool {
    p.chain_state == 2
        && p.ground_window > 0
        && speed_along_facing(p) >= 13.84
        && vel_facing_angle(p) <= 45.0
}

/// JP-10: previous jump was a single, landed at most 9 ticks ago.
fn double_ok(p: &PredInputs) -> bool {
    p.chain_state == 1 && p.ground_window > 0
}

/// AR-27: landed from jump/fall/edge, stick opposing facing and motion.
fn pivot_moving_ok(p: &PredInputs) -> bool {
    matches!(
        p.air_from.as_str(),
        "jump1" | "jump2" | "jump3" | "fall" | "coyote"
    ) && stick_radius(p) >= 0.1
        && {
            let f = facing_dir(p.facing);
            stick_angle_vs(p, f[0], f[1]) >= 95.0
        }
        && stick_angle_vs(p, p.vel[0], p.vel[2]) >= 95.0
}
