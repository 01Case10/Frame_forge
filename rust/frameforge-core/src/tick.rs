//! 60 Hz tick engine — faithful port of `behavior_player.gd`.
//!
//! Tick order (mirrors the GDScript comments):
//! 1. begin: rotate event sets; sample deterministic input edges.
//! 2. Row evaluation per sub-machine track, top-to-bottom, first true wins.
//!    Rows fire any time (interrupts); the frame is NOT advanced here.
//! 3. Per-track authored delta (with Preserve blending), summed and returned.
//!    (The Godot binding drives `move_and_slide` with the total.)
//! 4. Collision pass per track: contact edges, at most one response per track
//!    (priority floor > ceiling > wall), rearm-debounced gained edges.
//! 5. Behavior-level transitions, first true wins.
//! 6. Advance each track's frame (clamped at duration; `just_entered`
//!    tracks skip so frame 0 emits exactly once).
//!
//! Event visibility: transition/game events fired during tick N are visible
//! to On Event conditions at tick N+1. Contact-edge events are visible
//! immediately (`_emit_event_now`).

use crate::easing;
use crate::gesture::SpinDetector;
use crate::input::{InputState, TickInput};
use crate::logic::{LogicFactory, StateCtx, StateLogic};
use crate::model::*;
use crate::vec3::{Vec3, BACK, EPS, UP, ZERO};
use std::collections::{HashMap, HashSet};
use std::f32::consts::PI;

pub const TICKS_PER_SECOND: f32 = 60.0;
const DEFAULT_REARM_TICKS: u32 = 3;

/// Contact state for one tick, provided by the embedder (Godot binding or
/// headless harness). Normals are only read when a response fires.
#[derive(Debug, Clone)]
pub struct ContactState {
    pub floor: bool,
    pub ceiling: bool,
    pub wall: bool,
    pub floor_normal: Vec3,
    pub ceiling_normal: Vec3,
    pub wall_normal: Vec3,
    /// G-6: velocity of the touched object, units/second (Godot convention).
    /// ZERO for static geometry. Mirrors the `*_normal` fields.
    pub floor_velocity: Vec3,
    pub ceiling_velocity: Vec3,
    pub wall_velocity: Vec3,
}

impl ContactState {
    /// G-6: wall velocity in per-tick units (D8).
    pub fn wall_velocity_per_tick(&self) -> Vec3 {
        self.wall_velocity * (1.0 / TICKS_PER_SECOND)
    }
    /// G-6: floor velocity in per-tick units (D8).
    pub fn floor_velocity_per_tick(&self) -> Vec3 {
        self.floor_velocity * (1.0 / TICKS_PER_SECOND)
    }
    /// G-6: ceiling velocity in per-tick units (D8).
    pub fn ceiling_velocity_per_tick(&self) -> Vec3 {
        self.ceiling_velocity * (1.0 / TICKS_PER_SECOND)
    }
}

impl Default for ContactState {
    fn default() -> Self {
        Self {
            floor: false,
            ceiling: false,
            wall: false,
            floor_normal: UP,
            ceiling_normal: Vec3::new(0.0, -1.0, 0.0),
            wall_normal: ZERO,
            floor_velocity: ZERO,
            ceiling_velocity: ZERO,
            wall_velocity: ZERO,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StateRef {
    machine: usize,
    state: usize,
}

#[derive(Debug, Clone)]
#[allow(clippy::enum_variant_names)]
enum ResolvedCond {
    OnComplete,
    OnInput {
        actions: Vec<String>,
        mode: InputMode,
        /// G-1: press stays valid this many ticks after the press tick.
        buffer_ticks: u32,
    },
    OnVariable {
        name: String,
        op: Op,
        value: ParamValue,
    },
    OnEvent {
        name: String,
    },
    OnState {
        target: StateRef,
    },
    OnCustom {
        name: String,
    },
    /// G-2: stick radius + unsigned-angle check.
    OnStick {
        radius_min: f32,
        radius_max: f32,
        angle_vs: StickAngleVs,
        angle_min_deg: f32,
        angle_max_deg: f32,
    },
    /// Phase C: all sub-conditions must be true.
    AllOf(Vec<ResolvedCond>),
    /// Phase C: at least one sub-condition must be true.
    AnyOf(Vec<ResolvedCond>),
}

#[derive(Debug, Clone)]
struct ResolvedRow {
    cond: ResolvedCond,
    target: Option<StateRef>,
    target_behavior: String,
    momentum: Momentum,
    blend_frames: u32,
    fire_event: String,
    silent: bool,
    /// G-4: blackboard writes applied when the row fires.
    on_fire_params: Vec<ParamAssign>,
}

#[derive(Debug, Clone)]
struct ResolvedResp {
    target: Option<StateRef>,
    target_behavior: String,
    min_incoming_speed: f32,
    rearm_ticks: u32,
}

/// Floor / ceiling / wall slots.
const K_FLOOR: usize = 0;
const K_CEILING: usize = 1;
const K_WALL: usize = 2;

struct RtMachine {
    name: String,
    states: Vec<FrameState>,
    entry: usize,
    rows: Vec<Vec<ResolvedRow>>,
    resp: Vec<[Option<ResolvedResp>; 3]>,
    default_resp: [Option<ResolvedResp>; 3],
}

struct ResolvedBehavior {
    name: String,
    machines: Vec<RtMachine>,
    _machine_index: HashMap<String, usize>,
    parameters: Vec<Parameter>,
    behavior_transitions: Vec<ResolvedRow>,
    on_enter_event: String,
    on_exit_event: String,
    /// G-4: names armed by Countdown assigns (decremented each tick).
    countdown_params: HashSet<String>,
    /// G-4: spin-gesture detector config for the behavior.
    spin_detect: Option<SpinDetectConfig>,
}

struct Track {
    machine: usize,
    current: usize,
    frame: u32,
    magnitudes: Vec<f32>,
    entry_motion: Vec3,
    last_delta: Vec3,
    has_impact: bool,
    impact_normal: Vec3,
    impact_rate: f32,
    blend_from: Vec3,
    blend_total: u32,
    blend_left: u32,
    just_entered: bool,
    contact_prev: [bool; 3],
    rearm: [u32; 3],
    last_input_dir: Vec3,
    /// G-5: persistent velocity (units/tick), integrated by steering.
    velocity: Vec3,
    /// G-2/G-5: facing yaw in degrees. Facing vector = (sin yaw, 0, cos yaw).
    facing_yaw: f32,
    /// G-5: current angular velocity for the turn model (deg/tick).
    turn_vel: f32,
    /// G-6: active state-logic instance for this track's current state.
    /// `None` for pure data states.
    logic: Option<Box<dyn StateLogic>>,
    /// G-6: one-shot delta written by the logic's `on_enter`; consumed as
    /// the base delta by the next `compute_delta` (on_tick may overwrite).
    pending_enter_delta: Option<Vec3>,
}

impl Track {
    fn new(machine: usize, current: usize) -> Self {
        Self {
            machine,
            current,
            frame: 0,
            magnitudes: Vec::new(),
            entry_motion: ZERO,
            last_delta: ZERO,
            has_impact: false,
            impact_normal: UP,
            impact_rate: 0.0,
            blend_from: ZERO,
            blend_left: 0,
            blend_total: 0,
            just_entered: false,
            contact_prev: [false; 3],
            rearm: [99; 3],
            last_input_dir: ZERO,
            velocity: ZERO,
            facing_yaw: 0.0,
            turn_vel: 0.0,
            logic: None,
            pending_enter_delta: None,
        }
    }
}

/// Small copyable row payload for `_enter_state`.
#[derive(Clone, Copy)]
struct RowData {
    target: StateRef,
    momentum: Momentum,
    blend_frames: u32,
    silent: bool,
}

pub struct Runtime {
    resolved: ResolvedBehavior,
    registry: HashMap<String, FrameBehavior>,
    tracks: Vec<Track>,
    generation: u64,
    params: HashMap<String, ParamValue>,
    input: InputState,
    tracked_actions: Vec<String>,
    events_visible: HashSet<String>,
    events_pending: HashSet<String>,
    delta_phase_done: bool,
    tick_count: u64,
    custom_conditions: HashMap<String, Box<dyn Fn() -> bool>>,
    pending_entry: Vec3,
    has_pending_entry: bool,
    pending_just_entered: bool,
    switch_impact: Option<(Vec3, f32)>,
    /// Embedder-set yaw for camera-relative INPUT (radians). Godot reads a node.
    pub camera_yaw: f32,
    /// Debug: when true, logs OnVariable condition evaluations to stderr.
    /// Used for diagnosing trigger issues (e.g., AR-02).
    pub debug_conditions: bool,
    /// G-2/G-4/G-5: embedder-set stick vector (x right, y up/forward),
    /// length clamped to [0, 1]. The BehaviorPlayer maps Godot input to this.
    stick: [f32; 2],
    /// G-4: parameter names currently counting down (from Countdown assigns).
    countdown_params: HashSet<String>,
    /// G-4: stick spin-gesture detector.
    spin: SpinDetector,
    /// G-6: contact state from the previous tick (D3). State logic reads
    /// this during Phase A, when fresh contact isn't available yet.
    last_contact: ContactState,
    /// G-6: name -> factory for state-logic implementations. Pre-populated
    /// with built-ins; extend via `register_state_logic`.
    logic_registry: HashMap<String, LogicFactory>,
    // Inspection logs (replace Godot signals in headless use).
    pub event_log: Vec<String>,
    pub entered_log: Vec<(String, String, String)>,
    pub exited_log: Vec<(String, String, String)>,
    pub behavior_changed_log: Vec<(String, String)>,
    /// Unified signal order log: "exit B/M/S", "enter B/M/S", "behavior O->N".
    pub signal_log: Vec<String>,
}

// ---------------------------------------------------------------------------
// Construction / resolution
// ---------------------------------------------------------------------------

fn resolve_cond(
    c: &Condition,
    machines: &[RtMachine],
    machine_index: &HashMap<String, usize>,
) -> ResolvedCond {
    // Composite conditions (Phase C): when present, they define the
    // condition and the base cond_type is ignored.
    if !c.all_of.is_empty() || !c.any_of.is_empty() {
        let all: Vec<ResolvedCond> =
            c.all_of.iter().map(|s| resolve_cond(s, machines, machine_index)).collect();
        let any: Vec<ResolvedCond> =
            c.any_of.iter().map(|s| resolve_cond(s, machines, machine_index)).collect();
        if !all.is_empty() && !any.is_empty() {
            return ResolvedCond::AllOf(vec![
                ResolvedCond::AllOf(all),
                ResolvedCond::AnyOf(any),
            ]);
        }
        if !all.is_empty() {
            return ResolvedCond::AllOf(all);
        }
        return ResolvedCond::AnyOf(any);
    }
    match c.cond_type {
        ConditionType::OnComplete => ResolvedCond::OnComplete,
        ConditionType::OnInput => ResolvedCond::OnInput {
            actions: c.input_actions.clone(),
            mode: c.input_mode,
            buffer_ticks: c.buffer_ticks,
        },
        ConditionType::OnVariable => ResolvedCond::OnVariable {
            name: c.param_name.clone(),
            op: c.param_op,
            value: c.param_value.clone(),
        },
        ConditionType::OnEvent => ResolvedCond::OnEvent {
            name: c.event_name.clone(),
        },
        ConditionType::OnState => {
            let target = machine_index.get(&c.target_machine_name).and_then(|&mi| {
                machines[mi]
                    .states
                    .iter()
                    .position(|s| s.state_name == c.target_state_name)
                    .map(|si| StateRef {
                        machine: mi,
                        state: si,
                    })
            });
            // Unresolved OnState never fires (mirrors null resolved_state).
            ResolvedCond::OnState {
                target: target.unwrap_or(StateRef {
                    machine: usize::MAX,
                    state: usize::MAX,
                }),
            }
        }
        ConditionType::OnCustom => ResolvedCond::OnCustom {
            name: c.custom_name.clone(),
        },
        ConditionType::OnStick => ResolvedCond::OnStick {
            radius_min: c.stick_radius_min,
            radius_max: c.stick_radius_max,
            angle_vs: c.stick_angle_vs,
            angle_min_deg: c.stick_angle_min_deg,
            angle_max_deg: c.stick_angle_max_deg,
        },
    }
}

/// G-1: collect buffered-press actions from a (possibly composite) condition.
fn collect_buffered_actions(cond: &ResolvedCond, out: &mut Vec<String>) {
    match cond {
        ResolvedCond::OnInput {
            actions,
            mode: InputMode::AnyPressed,
            buffer_ticks,
        } if *buffer_ticks > 0 => out.extend(actions.iter().cloned()),
        ResolvedCond::AllOf(subs) | ResolvedCond::AnyOf(subs) => {
            for s in subs {
                collect_buffered_actions(s, out);
            }
        }
        _ => {}
    }
}

fn resolve_row(
    r: &Transition,
    state_index: &HashMap<String, usize>,
    machine_idx: usize,
    machines: &[RtMachine],
    machine_index: &HashMap<String, usize>,
) -> ResolvedRow {
    ResolvedRow {
        cond: resolve_cond(&r.condition, machines, machine_index),
        target: state_index.get(&r.target_state_name).map(|&si| StateRef {
            machine: machine_idx,
            state: si,
        }),
        target_behavior: r.target_behavior_name.clone(),
        momentum: r.momentum,
        blend_frames: r.blend_frames,
        fire_event: r.fire_event.clone(),
        silent: r.silent,
        on_fire_params: r.on_fire_params.clone(),
    }
}

fn resolve_resp(
    r: &ResponseRef,
    state_index: &HashMap<String, usize>,
    machine_idx: usize,
) -> ResolvedResp {
    ResolvedResp {
        target: state_index.get(&r.target_state_name).map(|&si| StateRef {
            machine: machine_idx,
            state: si,
        }),
        target_behavior: r.target_behavior_name.clone(),
        min_incoming_speed: r.min_incoming_speed,
        rearm_ticks: r.rearm_ticks,
    }
}

fn resolve_behavior(bh: &FrameBehavior) -> ResolvedBehavior {
    let mut machine_index = HashMap::new();
    for (mi, m) in bh.sub_machines.iter().enumerate() {
        machine_index.entry(m.machine_name.clone()).or_insert(mi);
    }
    // First pass: machines with state indices (needed for cross-machine
    // OnState resolution in the second pass).
    let mut machines: Vec<RtMachine> = Vec::new();
    for m in &bh.sub_machines {
        let mi = machines.len();
        let mut state_index = HashMap::new();
        for (si, s) in m.states.iter().enumerate() {
            state_index.entry(s.state_name.clone()).or_insert(si);
        }
        let entry = state_index.get(&m.entry_state_name).copied().unwrap_or(0);
        let resp: Vec<[Option<ResolvedResp>; 3]> = m
            .states
            .iter()
            .map(|s| {
                [
                    s.resp_floor
                        .as_ref()
                        .map(|r| resolve_resp(r, &state_index, mi)),
                    s.resp_ceiling
                        .as_ref()
                        .map(|r| resolve_resp(r, &state_index, mi)),
                    s.resp_wall
                        .as_ref()
                        .map(|r| resolve_resp(r, &state_index, mi)),
                ]
            })
            .collect();
        machines.push(RtMachine {
            name: m.machine_name.clone(),
            states: m.states.clone(),
            entry,
            rows: Vec::new(), // filled in second pass
            resp,
            default_resp: [
                m.default_resp_floor
                    .as_ref()
                    .map(|r| resolve_resp(r, &state_index, mi)),
                m.default_resp_ceiling
                    .as_ref()
                    .map(|r| resolve_resp(r, &state_index, mi)),
                m.default_resp_wall
                    .as_ref()
                    .map(|r| resolve_resp(r, &state_index, mi)),
            ],
        });
    }
    // Second pass: resolve rows now that all machines exist.
    for (mi, m) in bh.sub_machines.iter().enumerate() {
        let mut state_index = HashMap::new();
        for (si, s) in m.states.iter().enumerate() {
            state_index.entry(s.state_name.clone()).or_insert(si);
        }
        machines[mi].rows = m
            .states
            .iter()
            .map(|s| {
                s.transitions
                    .iter()
                    .map(|r| resolve_row(r, &state_index, mi, &machines, &machine_index))
                    .collect()
            })
            .collect();
    }
    let behavior_transitions = bh
        .behavior_transitions
        .iter()
        .map(|r| {
            // Behavior-level rows resolve against machine 0's states for
            // target (unused in practice); keep None when unresolvable.
            let state_index: HashMap<String, usize> = HashMap::new();
            resolve_row(r, &state_index, usize::MAX, &machines, &machine_index)
        })
        .collect();
    ResolvedBehavior {
        name: bh.behavior_name.clone(),
        machines,
        _machine_index: machine_index,
        parameters: bh.parameters.clone(),
        behavior_transitions,
        on_enter_event: bh.on_enter_event.clone(),
        on_exit_event: bh.on_exit_event.clone(),
        countdown_params: collect_countdowns(bh),
        spin_detect: bh.spin_detect.clone(),
    }
}

/// G-4: gather every parameter name armed by a Countdown assign, anywhere in
/// the behavior (state enter_params, transition on_fire_params, and
/// behavior-level rows).
fn collect_countdowns(bh: &FrameBehavior) -> HashSet<String> {
    fn gather_row(into: &mut HashSet<String>, t: &Transition) {
        for a in &t.on_fire_params {
            if let ParamAssign::Countdown { name, .. } = a {
                if !name.is_empty() {
                    into.insert(name.clone());
                }
            }
        }
    }
    fn gather_state(into: &mut HashSet<String>, s: &FrameState) {
        for a in &s.enter_params {
            if let ParamAssign::Countdown { name, .. } = a {
                if !name.is_empty() {
                    into.insert(name.clone());
                }
            }
        }
        for t in &s.transitions {
            gather_row(into, t);
        }
    }
    let mut out = HashSet::new();
    for m in &bh.sub_machines {
        for s in &m.states {
            gather_state(&mut out, s);
        }
    }
    for t in &bh.behavior_transitions {
        gather_row(&mut out, t);
    }
    out
}

impl Runtime {
    pub fn new(behavior: FrameBehavior) -> Self {
        let mut rt = Self {
            resolved: resolve_behavior(&behavior),
            registry: HashMap::new(),
            tracks: Vec::new(),
            generation: 0,
            params: HashMap::new(),
            input: InputState::default(),
            tracked_actions: Vec::new(),
            events_visible: HashSet::new(),
            events_pending: HashSet::new(),
            delta_phase_done: false,
            tick_count: 0,
            custom_conditions: HashMap::new(),
            pending_entry: ZERO,
            has_pending_entry: false,
            pending_just_entered: false,
            switch_impact: None,
            camera_yaw: 0.0,
            stick: [0.0, 0.0],
            countdown_params: HashSet::new(),
            spin: SpinDetector::new(),
            last_contact: ContactState::default(),
            logic_registry: HashMap::new(),
            event_log: Vec::new(),
            entered_log: Vec::new(),
            exited_log: Vec::new(),
            behavior_changed_log: Vec::new(),
            signal_log: Vec::new(),
            debug_conditions: false,
        };
        rt.registry.insert(behavior.behavior_name.clone(), behavior);
        rt.collect_input_actions();
        // G-6: built-in state logics, before rebuild() enters entry states.
        rt.logic_registry = crate::logics::builtin_registry();
        rt.rebuild();
        rt
    }

    pub fn register_behavior(&mut self, behavior: FrameBehavior) {
        self.registry
            .insert(behavior.behavior_name.clone(), behavior);
    }

    pub fn register_custom_condition(&mut self, name: &str, f: Box<dyn Fn() -> bool>) {
        self.custom_conditions.insert(name.to_string(), f);
    }

    /// G-6: register a state-logic factory under `name`. States with
    /// `logic: Some(name)` instantiate it on entry. Unknown names are a
    /// validation error; the runtime never panics on them. Tracks already
    /// sitting in a state that names it (e.g. entry states, entered during
    /// `rebuild` before this could be called) get their `on_enter` now.
    pub fn register_state_logic(&mut self, name: &str, f: LogicFactory) {
        self.logic_registry.insert(name.to_string(), f);
        let mut to_enter = Vec::new();
        for (t_idx, t) in self.tracks.iter().enumerate() {
            if t.logic.is_none() {
                let st = &self.resolved.machines[t.machine].states[t.current];
                if st.logic.as_deref() == Some(name) {
                    to_enter.push(t_idx);
                }
            }
        }
        for t_idx in to_enter {
            self.run_logic_enter(t_idx);
        }
    }

    pub fn set_param(&mut self, name: &str, v: ParamValue) {
        self.params.insert(name.to_string(), v);
    }

    pub fn get_param(&self, name: &str) -> Option<&ParamValue> {
        self.params.get(name)
    }

    pub fn has_param(&self, name: &str) -> bool {
        self.params.contains_key(name)
    }

    /// G-2/G-4/G-5: set the stick vector (x right, y up/forward; length
    /// clamped to [0, 1]). Call once per tick before `tick_delta`. The spin
    /// detector is fed from this same value at the start of the tick.
    pub fn set_stick(&mut self, x: f32, y: f32) {
        let len = (x * x + y * y).sqrt();
        self.stick = if len > 1.0 {
            [x / len, y / len]
        } else {
            [x, y]
        };
    }

    /// G-2/G-5: set every track's facing yaw (degrees). The BehaviorPlayer
    /// calls this once at spawn from the character's facing.
    pub fn set_facing_yaw(&mut self, yaw_deg: f32) {
        for t in &mut self.tracks {
            t.facing_yaw = yaw_deg;
        }
    }

    fn track_idx(&self, machine: &str) -> Option<usize> {
        let mi = self.resolved._machine_index.get(machine).copied()?;
        self.tracks.iter().position(|t| t.machine == mi)
    }

    /// G-5: the named machine's track velocity (units/tick). ZERO if unknown.
    pub fn track_velocity(&self, machine: &str) -> Vec3 {
        self.track_idx(machine)
            .map(|ti| self.tracks[ti].velocity)
            .unwrap_or(ZERO)
    }

    /// G-2/G-5: the named machine's track facing yaw (degrees). 0.0 if unknown.
    /// Force a track into a state by name (bridge-driven transitions).
    /// Used for external events (damage, death, pit) that bypass row logic.
    /// Returns false if machine/state not found.
    pub fn force_state(&mut self, machine: &str, state_name: &str) -> bool {
        // Find machine and state indices.
        let (mi, si) = match self
            .resolved
            .machines
            .iter()
            .position(|m| m.name == machine)
            .and_then(|mi| {
                self.resolved.machines[mi]
                    .states
                    .iter()
                    .position(|s| s.state_name == state_name)
                    .map(|si| (mi, si))
            }) {
            Some(v) => v,
            None => return false,
        };
        // Find the track for this machine.
        let t_idx = match self.tracks.iter().position(|t| t.machine == mi) {
            Some(i) => i,
            None => return false,
        };
        let target = StateRef {
            machine: mi,
            state: si,
        };
        // No impact (bridge-driven, not collision).
        self.enter_state(t_idx, target, None, Vec3::new(0.0, 0.0, 0.0), 0.0, false);
        true
    }

    pub fn track_facing_yaw(&self, machine: &str) -> f32 {
        self.track_idx(machine)
            .map(|ti| self.tracks[ti].facing_yaw)
            .unwrap_or(0.0)
    }

    /// Game-code event emission (public API, mirrors `emit_event`).
    /// Visible to On Event conditions starting next tick.
    pub fn emit_event(&mut self, name: &str) {
        self.push_event(name);
    }

    pub fn behavior_name(&self) -> &str {
        &self.resolved.name
    }

    pub fn tick_count(&self) -> u64 {
        self.tick_count
    }

    fn collect_input_actions(&mut self) {
        let mut seen = HashSet::new();
        let mut gather = |r: &ResolvedRow| {
            if let ResolvedCond::OnInput { actions, .. } = &r.cond {
                for a in actions {
                    seen.insert(a.clone());
                }
            }
        };
        for r in &self.resolved.behavior_transitions {
            gather(r);
        }
        for m in &self.resolved.machines {
            for rows in &m.rows {
                for r in rows {
                    gather(r);
                }
            }
        }
        let mut v: Vec<String> = seen.into_iter().collect();
        v.sort();
        self.tracked_actions = v;
    }

    pub fn tracked_actions(&self) -> &[String] {
        &self.tracked_actions
    }

    fn rebuild(&mut self) {
        let old_params = std::mem::take(&mut self.params);
        self.tracks.clear();
        // G-4: refresh countdown registry + spin detector for the behavior.
        self.countdown_params = self.resolved.countdown_params.clone();
        self.spin.configure(self.resolved.spin_detect.clone());
        for p in &self.resolved.parameters {
            let v = old_params
                .get(&p.name)
                .cloned()
                .unwrap_or_else(|| p.default_value.clone());
            self.params.insert(p.name.clone(), v);
        }
        for mi in 0..self.resolved.machines.len() {
            let entry = self.resolved.machines[mi].entry;
            let mut t = Track::new(mi, entry);
            if self.has_pending_entry {
                t.entry_motion = self.pending_entry;
                t.just_entered = self.pending_just_entered;
            }
            self.tracks.push(t);
            let ti = self.tracks.len() - 1;
            self.precompute(ti);
            // G-5: seed steering velocity for steered entry states.
            self.init_steer_velocity(ti);
            if let Some((n, rate)) = self.switch_impact {
                let t = &mut self.tracks[ti];
                t.has_impact = true;
                t.impact_normal = n;
                t.impact_rate = rate;
            }
            // G-6: enter the entry state's logic, if any. `rebuild` doesn't
            // go through `enter_state`, so this is the only place entry
            // states get their logic instances.
            self.run_logic_enter(ti);
        }
        self.generation += 1;
    }

    // ---------------------------------------------------------------- tick

    /// Advance one 60 Hz tick. Returns the summed per-track delta (meters).
    /// Convenience wrapper; embedders with real physics use
    /// `tick_delta` / `tick_contact` to interleave the move.
    pub fn tick(&mut self, input: &TickInput, contact: &ContactState) -> Vec3 {
        let d = self.tick_delta(input);
        self.tick_contact(contact);
        d
    }

    /// Tick phase A: input edges, row evaluation, per-track deltas.
    /// Returns the summed delta; the embedder moves the body, then calls
    /// `tick_contact` with the resulting contact state.
    pub fn tick_delta(&mut self, input: &TickInput) -> Vec3 {
        self.begin_tick(input);

        // 2. Row evaluation.
        let gen = self.generation;
        let n = self.tracks.len();
        for t_idx in 0..n {
            if self.generation != gen || t_idx >= self.tracks.len() {
                break;
            }
            self.evaluate_rows(t_idx);
        }

        // 3. Deltas.
        let mut total = ZERO;
        for t_idx in 0..self.tracks.len() {
            self.emit_frame_events(t_idx);
            let d = self.compute_delta(t_idx);
            self.tracks[t_idx].last_delta = d;
            total = total + d;
        }
        self.delta_phase_done = true;
        total
    }

    /// Tick phase B: collision pass, behavior transitions, frame advance.
    pub fn tick_contact(&mut self, contact: &ContactState) {
        // G-6: stash for state logic, which reads it during the next tick's
        // Phase A (D3).
        self.last_contact = contact.clone();
        // 4. Collision pass.
        let gen = self.generation;
        let snapshot: Vec<usize> = (0..self.tracks.len()).collect();
        for t_idx in snapshot {
            if self.generation != gen || t_idx >= self.tracks.len() {
                break;
            }
            self.track_collision(t_idx, contact);
        }

        // 5. Behavior transitions.
        self.behavior_transitions();

        // 6. Advance frames.
        for t_idx in 0..self.tracks.len() {
            self.advance_frame(t_idx);
        }

        self.end_tick();
        self.tick_count += 1;
    }

    fn begin_tick(&mut self, input: &TickInput) {
        self.events_visible = std::mem::take(&mut self.events_pending);
        self.delta_phase_done = false;
        self.input.begin_tick(input);
        // G-4: countdown params tick down at the start of each tick. A
        // Countdown armed during tick t reads its full value for the rest of
        // tick t, then decrements here each tick until 0.
        if !self.countdown_params.is_empty() {
            let names: Vec<String> = self.countdown_params.iter().cloned().collect();
            for n in names {
                match self.params.get(&n).cloned() {
                    Some(ParamValue::Int(i)) if i > 0 => {
                        self.params.insert(n, ParamValue::Int(i - 1));
                    }
                    Some(ParamValue::Float(f)) if f > 0.0 => {
                        self.params.insert(n, ParamValue::Float(f - 1.0));
                    }
                    _ => {}
                }
            }
        }
        // G-4: feed the spin detector from the embedder-set stick and publish
        // its output, so conditions see it during this tick's row evaluation.
        let [sx, sy] = self.stick;
        self.spin.push_stick(sx, sy);
        if let Some(name) = self.spin.output_param().map(|s| s.to_string()) {
            let v = self.spin.valid();
            self.params.insert(name, ParamValue::Bool(v));
        }
    }

    fn end_tick(&mut self) {
        self.input.end_tick();
    }

    /// G-4: apply one blackboard write (transition fire or state enter).
    fn apply_param_assign(&mut self, a: &ParamAssign) {
        match a {
            ParamAssign::Set { name, value } => {
                if !name.is_empty() {
                    self.params.insert(name.clone(), value.clone());
                }
            }
            ParamAssign::Countdown { name, ticks } => {
                if !name.is_empty() {
                    self.params.insert(name.clone(), ParamValue::Int(*ticks as i64));
                }
            }
        }
    }

    /// G-5: (re)initialize a track's steering velocity on entering a steered
    /// state. Horizontal velocity seeds from the incoming motion unless the
    /// state opts out; vertical velocity follows `enter_vy`. Non-steered
    /// states leave velocity untouched (it is simply unused there).
    fn init_steer_velocity(&mut self, t_idx: usize) {
        let (mi, si) = {
            let t = &self.tracks[t_idx];
            (t.machine, t.current)
        };
        let steer = match &self.resolved.machines[mi].states[si].steer {
            Some(s) => s.clone(),
            None => return,
        };
        let t = &mut self.tracks[t_idx];
        if steer.enter_keep_horizontal {
            t.velocity.x = t.entry_motion.x;
            t.velocity.z = t.entry_motion.z;
        } else {
            t.velocity.x = 0.0;
            t.velocity.z = 0.0;
        }
        // Launch along the last impact normal (e.g. away from the wall).
        if steer.enter_impact_speed > 0.0 && t.has_impact {
            let n = t.impact_normal;
            let nl = (n.x * n.x + n.z * n.z).sqrt();
            if nl > 1e-6 {
                t.velocity.x = n.x / nl * steer.enter_impact_speed;
                t.velocity.z = n.z / nl * steer.enter_impact_speed;
            }
        }
        match steer.enter_vy {
            EnterVy::Keep => {}
            EnterVy::Set(v) => t.velocity.y = v,
            EnterVy::Add(v) => t.velocity.y += v,
        }
        t.turn_vel = 0.0;
    }

    fn evaluate_rows(&mut self, t_idx: usize) {
        let (mi, si) = {
            let t = &self.tracks[t_idx];
            (t.machine, t.current)
        };
        let n_rows = self.resolved.machines[mi].rows[si].len();
        for ri in 0..n_rows {
            let fire = {
                let row = &self.resolved.machines[mi].rows[si][ri];
                self.condition_true(Some(t_idx), &row.cond)
            };
            if fire {
                // Copy out the small fields to end the borrow.
                let (
                    target,
                    target_behavior,
                    fire_event,
                    momentum,
                    blend_frames,
                    silent,
                    on_fire_params,
                    consume,
                ) = {
                    let row = &self.resolved.machines[mi].rows[si][ri];
                    // G-1: a firing buffered row consumes the press
                    // (recurses into composites).
                    let consume = {
                        let mut acts = Vec::new();
                        collect_buffered_actions(&row.cond, &mut acts);
                        if acts.is_empty() {
                            None
                        } else {
                            Some(acts)
                        }
                    };
                    (
                        row.target,
                        row.target_behavior.clone(),
                        row.fire_event.clone(),
                        row.momentum,
                        row.blend_frames,
                        row.silent,
                        row.on_fire_params.clone(),
                        consume,
                    )
                };
                // G-4: blackboard writes from the firing row.
                for a in &on_fire_params {
                    self.apply_param_assign(a);
                }
                if let Some(actions) = consume {
                    for a in &actions {
                        self.input.consume_press(a);
                    }
                }
                if !fire_event.is_empty() {
                    self.push_event(&fire_event);
                }
                if !target_behavior.is_empty() {
                    self.switch_behavior(&target_behavior);
                    return;
                }
                if let Some(tgt) = target {
                    let rd = RowData {
                        target: tgt,
                        momentum,
                        blend_frames,
                        silent,
                    };
                    self.enter_state(t_idx, tgt, Some(rd), UP, 0.0, false);
                }
                // Unresolved target: hold (mirrors null resolved_state).
                return;
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    // ---------------------------------------------------------------- G-6
    // State logic (trait-based custom states).
    /// Build a [`StateCtx`] from disjoint field borrows and hand it to `f`.
    /// The `&mut self` is split per-field so the logic sees a narrow
    /// capability window and nothing else.
    fn logic_ctx<R>(
        &mut self,
        t_idx: usize,
        delta: &mut Vec3,
        f: impl FnOnce(&mut StateCtx) -> R,
    ) -> R {
        let t = &mut self.tracks[t_idx];
        let frame = t.frame;
        let facing_yaw = &mut t.facing_yaw;
        let input = &self.input;
        let stick = self.stick;
        // World-space stick direction (same mapping as `stick_world_dir`).
        let (sx, sy) = (stick[0], stick[1]);
        let (s, c) = self.camera_yaw.sin_cos();
        let fwd = Vec3::new(-s, 0.0, -c);
        let right = Vec3::new(c, 0.0, -s);
        let stick_world = (right * sx + fwd * (-sy)).safe_normalized();
        let params = &mut self.params;
        let contact = &self.last_contact;
        let events_pending = &mut self.events_pending;
        let event_log = &mut self.event_log;
        // Mirrors `push_event`: visible to engine OnEvent at N+1, to the
        // game as `event_fired` at end of tick N (D6).
        let mut fire = |name: &str| {
            if name.is_empty() {
                return;
            }
            events_pending.insert(name.to_string());
            event_log.push(name.to_string());
        };
        let mut ctx = StateCtx {
            input,
            stick,
            stick_world,
            params,
            contact,
            frame,
            facing_yaw,
            delta,
            fire: &mut fire,
        };
        f(&mut ctx)
    }

    /// G-6: run the outgoing track logic's `on_exit`, if any, and drop the
    /// instance. The slot is empty afterwards.
    fn run_logic_exit(&mut self, t_idx: usize) {
        let mut logic = match self.tracks.get_mut(t_idx).and_then(|t| t.logic.take()) {
            Some(l) => l,
            None => return,
        };
        let mut delta = ZERO;
        self.logic_ctx(t_idx, &mut delta, |ctx| {
            logic.on_exit(ctx);
        });
        // `logic` drops here.
    }

    /// G-6: construct the new state's logic from the registry (if the state
    /// names one and it's registered) and run `on_enter`. Unknown names are
    /// a validation error, never a runtime panic.
    fn run_logic_enter(&mut self, t_idx: usize) {
        let name = {
            let t = &self.tracks[t_idx];
            match self.resolved.machines[t.machine].states[t.current].logic.clone() {
                Some(n) => n,
                None => return,
            }
        };
        let mut logic = match self.logic_registry.get(&name) {
            Some(f) => f(),
            None => return,
        };
        let mut delta = ZERO;
        self.logic_ctx(t_idx, &mut delta, |ctx| {
            logic.on_enter(ctx);
        });
        // The entry delta becomes this tick's base delta (on_tick runs
        // after and may overwrite it). A logic owns its delta.
        self.tracks[t_idx].pending_enter_delta = Some(delta);
        self.tracks[t_idx].logic = Some(logic);
    }

    /// G-6: run the active logic's `on_tick`, letting it rewrite `delta`.
    /// No-op for pure data states.
    fn run_logic_tick(&mut self, t_idx: usize, delta: &mut Vec3) {
        let mut logic = match self.tracks.get_mut(t_idx).and_then(|t| t.logic.take()) {
            Some(l) => l,
            None => return,
        };
        self.logic_ctx(t_idx, delta, |ctx| {
            logic.on_tick(ctx);
        });
        self.tracks[t_idx].logic = Some(logic);
    }

    fn enter_state(
        &mut self,
        t_idx: usize,
        target: StateRef,
        row: Option<RowData>,
        impact_normal: Vec3,
        impact_rate: f32,
        has_impact: bool,
    ) {
        let (old_mi, old_si) = {
            let t = &self.tracks[t_idx];
            (t.machine, t.current)
        };
        let silent_self = match row {
            Some(r) => r.silent && old_mi == r.target.machine && old_si == r.target.state,
            None => false,
        };
        let machine_name = self.resolved.machines[old_mi].name.clone();
        let old_name = self.resolved.machines[old_mi].states[old_si]
            .state_name
            .clone();
        if !silent_self {
            self.exited_log.push((
                self.resolved.name.clone(),
                machine_name.clone(),
                old_name.clone(),
            ));
            self.signal_log.push(format!(
                "exit {}/{}/{}",
                self.resolved.name, machine_name, old_name
            ));
            self.emit_state_events(old_mi, old_si, EventTrigger::OnExit);
            // G-6: exit the old state's logic, if any.
            self.run_logic_exit(t_idx);
        }
        {
            let t = &mut self.tracks[t_idx];
            t.entry_motion = t.last_delta;
            t.machine = target.machine;
            t.current = target.state;
            t.frame = 0;
            t.just_entered = self.delta_phase_done;
            // Preserve last impact info across row transitions (only a new
            // collision overwrites it); wall jumps read the wall normal here.
            if has_impact {
                t.has_impact = true;
                t.impact_normal = impact_normal;
                t.impact_rate = impact_rate;
            }
            match row {
                Some(r) if r.momentum == Momentum::Preserve && r.blend_frames > 0 => {
                    let dur = self.resolved.machines[target.machine].states[target.state]
                        .duration_frames
                        .max(1);
                    t.blend_total = r.blend_frames.min(dur);
                    t.blend_left = t.blend_total;
                    t.blend_from = t.entry_motion;
                }
                _ => {
                    t.blend_total = 0;
                    t.blend_left = 0;
                }
            }
        }
        // G-4: the new state's enter_params.
        let enter_params = self.resolved.machines[target.machine].states[target.state]
            .enter_params
            .clone();
        for a in &enter_params {
            self.apply_param_assign(a);
        }
        // G-5: seed steering velocity for steered states.
        self.init_steer_velocity(t_idx);
        self.precompute(t_idx);
        // G-6: enter the new state's logic, if any.
        if !silent_self {
            self.run_logic_enter(t_idx);
        }
        if !silent_self {
            let new_name = self.resolved.machines[target.machine].states[target.state]
                .state_name
                .clone();
            self.entered_log.push((
                self.resolved.name.clone(),
                machine_name.clone(),
                new_name.clone(),
            ));
            self.signal_log.push(format!(
                "enter {}/{}/{}",
                self.resolved.name, machine_name, new_name
            ));
            self.emit_state_events(target.machine, target.state, EventTrigger::OnEnter);
        }
    }

    fn switch_behavior(&mut self, name: &str) {
        if name == self.resolved.name {
            return;
        }
        let bh = match self.registry.get(name) {
            Some(b) => b.clone(),
            None => return,
        };
        let old_name = self.resolved.name.clone();
        for t_idx in 0..self.tracks.len() {
            let (mi, si, mn, sn) = {
                let t = &self.tracks[t_idx];
                let m = &self.resolved.machines[t.machine];
                (
                    t.machine,
                    t.current,
                    m.name.clone(),
                    m.states[t.current].state_name.clone(),
                )
            };
            self.exited_log
                .push((self.resolved.name.clone(), mn.clone(), sn.clone()));
            self.signal_log
                .push(format!("exit {}/{}/{}", self.resolved.name, mn, sn));
            self.emit_state_events(mi, si, EventTrigger::OnExit);
            // G-6: exit the old state's logic, if any.
            self.run_logic_exit(t_idx);
        }
        if !self.resolved.on_exit_event.is_empty() {
            let e = self.resolved.on_exit_event.clone();
            self.push_event(&e);
        }
        let mut total_last = ZERO;
        for t in &self.tracks {
            total_last = total_last + t.last_delta;
        }
        self.pending_entry = total_last;
        self.has_pending_entry = true;
        self.pending_just_entered = self.delta_phase_done;
        self.resolved = resolve_behavior(&bh);
        self.rebuild();
        // Clear AFTER rebuild (mirrors the GDScript setter ordering).
        self.has_pending_entry = false;
        self.pending_just_entered = false;
        // Apply stashed impact (set by _fire_response before switching).
        // (Handled inside rebuild via switch_impact.)
        self.switch_impact = None;
        self.behavior_changed_log
            .push((old_name.clone(), name.to_string()));
        self.signal_log
            .push(format!("behavior {}->{}", old_name, name));
        if !self.resolved.on_enter_event.is_empty() {
            let e = self.resolved.on_enter_event.clone();
            self.push_event(&e);
        }
        for t_idx in 0..self.tracks.len() {
            let (mi, si, mn, sn) = {
                let t = &self.tracks[t_idx];
                let m = &self.resolved.machines[t.machine];
                (
                    t.machine,
                    t.current,
                    m.name.clone(),
                    m.states[t.current].state_name.clone(),
                )
            };
            self.entered_log
                .push((self.resolved.name.clone(), mn.clone(), sn.clone()));
            self.signal_log
                .push(format!("enter {}/{}/{}", self.resolved.name, mn, sn));
            self.emit_state_events(mi, si, EventTrigger::OnEnter);
        }
        self.collect_input_actions();
    }

    // ------------------------------------------------------------ conditions

    fn condition_true(&self, t_idx: Option<usize>, cond: &ResolvedCond) -> bool {
        match cond {
            ResolvedCond::OnComplete => match t_idx {
                Some(ti) => {
                    let t = &self.tracks[ti];
                    let dur = self.resolved.machines[t.machine].states[t.current]
                        .duration_frames
                        .max(1);
                    t.frame >= dur
                }
                None => false,
            },
            ResolvedCond::OnInput {
                actions,
                mode,
                buffer_ticks,
            } => {
                if actions.is_empty() {
                    return false;
                }
                match mode {
                    InputMode::AnyPressed => {
                        if *buffer_ticks > 0 {
                            // G-1: press valid for buffer_ticks after the press tick.
                            actions
                                .iter()
                                .any(|a| self.input.pressed_within(a, *buffer_ticks))
                        } else {
                            actions.iter().any(|a| self.input.just_pressed.contains(a))
                        }
                    }
                    InputMode::AnyReleased => {
                        actions.iter().any(|a| self.input.just_released.contains(a))
                    }
                    InputMode::AllReleased => {
                        let any_down_now = actions.iter().any(|a| self.input.held.contains(a));
                        if any_down_now {
                            return false;
                        }
                        actions.iter().any(|a| self.input.was_held(a))
                    }
                    InputMode::AnyHeld => actions.iter().any(|a| self.input.held.contains(a)),
                    InputMode::NoneHeld => !actions.iter().any(|a| self.input.held.contains(a)),
                }
            }
            ResolvedCond::OnVariable { name, op, value } => {
                // G-3: the reserved state_step param reads the track's frame.
                if name == STATE_STEP_PARAM {
                    return match t_idx {
                        Some(ti) => compare_param(
                            op,
                            &ParamValue::Float(self.tracks[ti].frame as f64),
                            value,
                        ),
                        None => false,
                    };
                }
                let v = match self.params.get(name) {
                    Some(v) => v,
                    None => {
                        if self.debug_conditions {
                            eprintln!("[cond] {}: MISSING (expected {:?})", name, value);
                        }
                        return false;
                    }
                };
                let result = compare_param(op, v, value);
                if self.debug_conditions {
                    eprintln!(
                        "[cond] {} {:?} {:?} (actual {:?}) => {}",
                        name, op, value, v, result
                    );
                }
                result
            }
            ResolvedCond::OnEvent { name } => self.events_visible.contains(name),
            ResolvedCond::OnState { target } => {
                if target.machine == usize::MAX {
                    return false;
                }
                self.tracks
                    .iter()
                    .any(|t| t.machine == target.machine && t.current == target.state)
            }
            ResolvedCond::OnCustom { name } => self
                .custom_conditions
                .get(name)
                .map(|f| f())
                .unwrap_or(false),
            ResolvedCond::OnStick {
                radius_min,
                radius_max,
                angle_vs,
                angle_min_deg,
                angle_max_deg,
            } => {
                // G-2: stick radius + unsigned angle vs facing / velocity.
                let ti = match t_idx {
                    Some(ti) => ti,
                    None => return false,
                };
                let (sx, sy) = (self.stick[0], self.stick[1]);
                let r = (sx * sx + sy * sy).sqrt();
                if r < *radius_min || r > *radius_max {
                    return false;
                }
                // A full 0-180 degree range is vacuous (pure radius checks
                // like stick_neutral); only measure an angle when the range
                // is restrictive, which needs a measurable direction.
                let restrictive = *angle_min_deg > 0.0 || *angle_max_deg < 180.0;
                if !restrictive {
                    return true;
                }
                if r < 1e-6 {
                    return false; // no direction to measure an angle against
                }
                let stick_dir = self.stick_world_dir();
                let ref_dir = match angle_vs {
                    StickAngleVs::Facing => Some(facing_dir(self.tracks[ti].facing_yaw)),
                    StickAngleVs::Velocity => self.track_horizontal_dir(ti),
                };
                let rd = match ref_dir {
                    Some(d) => d,
                    None => return false,
                };
                let ang_deg = stick_dir.angle_to(rd) * 180.0 / PI;
                ang_deg >= *angle_min_deg && ang_deg <= *angle_max_deg
            }
            ResolvedCond::AllOf(subs) => {
                subs.iter().all(|s| self.condition_true(t_idx, s))
            }
            ResolvedCond::AnyOf(subs) => {
                subs.iter().any(|s| self.condition_true(t_idx, s))
            }
        }
    }

    /// Stick world direction (XZ, unit length) using the same camera-relative
    /// mapping as `input_direction`. `set_stick(0, 1)` matches a held
    /// "forward" input action.
    fn stick_world_dir(&self) -> Vec3 {
        let (sx, sy) = (self.stick[0], self.stick[1]);
        let (s, c) = self.camera_yaw.sin_cos();
        let fwd = Vec3::new(-s, 0.0, -c);
        let right = Vec3::new(c, 0.0, -s);
        (right * sx + fwd * (-sy)).safe_normalized()
    }

    /// Horizontal direction of the track's motion: steering velocity first,
    /// falling back to last tick's delta. None when not moving.
    fn track_horizontal_dir(&self, t_idx: usize) -> Option<Vec3> {
        let t = &self.tracks[t_idx];
        let v = Vec3::new(t.velocity.x, 0.0, t.velocity.z);
        if v.length() > 1e-6 {
            return Some(v.normalized());
        }
        let d = Vec3::new(t.last_delta.x, 0.0, t.last_delta.z);
        if d.length() > 1e-6 {
            return Some(d.normalized());
        }
        None
    }

    // ---------------------------------------------------------------- events

    fn push_event(&mut self, name: &str) {
        if name.is_empty() {
            return;
        }
        self.events_pending.insert(name.to_string());
        self.event_log.push(name.to_string());
    }

    fn emit_event_now(&mut self, name: &str) {
        if name.is_empty() {
            return;
        }
        self.events_visible.insert(name.to_string());
        self.event_log.push(name.to_string());
    }

    fn emit_state_events(&mut self, mi: usize, si: usize, trig: EventTrigger) {
        let names: Vec<String> = self.resolved.machines[mi].states[si]
            .events
            .iter()
            .filter(|e| e.trigger == trig && !e.event_name.is_empty())
            .map(|e| e.event_name.clone())
            .collect();
        for n in names {
            self.push_event(&n);
        }
    }

    fn emit_frame_events(&mut self, t_idx: usize) {
        let (mi, si, frame) = {
            let t = &self.tracks[t_idx];
            (t.machine, t.current, t.frame)
        };
        let names: Vec<String> = self.resolved.machines[mi].states[si]
            .events
            .iter()
            .filter(|e| {
                e.trigger == EventTrigger::OnFrame && e.frame == frame && !e.event_name.is_empty()
            })
            .map(|e| e.event_name.clone())
            .collect();
        for n in names {
            self.push_event(&n);
        }
    }

    // --------------------------------------------------------------- motion

    fn precompute(&mut self, t_idx: usize) {
        let (mi, si) = {
            let t = &self.tracks[t_idx];
            (t.machine, t.current)
        };
        let st = &self.resolved.machines[mi].states[si];
        let n = st.duration_frames.max(1) as usize;
        let mut magnitudes = vec![0.0f32; n];
        let mut ds = st.displacement_source;
        let t = &self.tracks[t_idx];
        if ds == DisplacementSource::Incoming && !t.has_impact {
            ds = DisplacementSource::Author;
        }
        match ds {
            DisplacementSource::Incoming => {
                let rate = t.impact_rate * st.restitution;
                for (k, m) in magnitudes.iter_mut().enumerate() {
                    *m = rate * easing::sample(&st.easing, k as f32 / n as f32);
                }
            }
            DisplacementSource::Entry => {
                let rate = t.entry_motion.length();
                for (k, m) in magnitudes.iter_mut().enumerate() {
                    *m = rate * easing::sample(&st.easing, k as f32 / n as f32);
                }
            }
            DisplacementSource::Author => {
                let mut wsum = 0.0f32;
                let mut weights = vec![0.0f32; n];
                for (k, w) in weights.iter_mut().enumerate() {
                    let s = easing::sample(&st.easing, k as f32 / n as f32);
                    *w = s;
                    wsum += s;
                }
                if wsum >= EPS {
                    for (k, m) in magnitudes.iter_mut().enumerate() {
                        *m = st.displacement * weights[k] / wsum;
                    }
                }
            }
        }
        self.tracks[t_idx].magnitudes = magnitudes;
    }

    fn compute_delta(&mut self, t_idx: usize) -> Vec3 {
        let (mi, si) = {
            let t = &self.tracks[t_idx];
            (t.machine, t.current)
        };
        // G-5: steered states integrate a persistent velocity instead of
        // authored displacement x easing.
        // G-6: the logic's on_enter delta (if any) is this tick's base.
        let mut delta = match self.tracks[t_idx].pending_enter_delta.take() {
            Some(d) => d,
            None => {
                let steer = self.resolved.machines[mi].states[si].steer.clone();
                match steer {
                    Some(s) => self.apply_steer(t_idx, &s),
                    None => {
                        let dir = self.resolve_direction(t_idx, mi, si);
                        let t = &self.tracks[t_idx];
                        let k = (t.frame as usize).min(t.magnitudes.len().saturating_sub(1));
                        dir * t.magnitudes[k]
                    }
                }
            }
        };
        // G-6: active state logic may rewrite the delta before blending.
        self.run_logic_tick(t_idx, &mut delta);
        let t = &self.tracks[t_idx];
        if t.blend_left > 0 && t.blend_total > 0 {
            let elapsed = t.blend_total - t.blend_left;
            let w = ((elapsed + 1) as f32 / t.blend_total as f32).clamp(0.0, 1.0);
            t.blend_from.lerp(delta, w)
        } else {
            delta
        }
    }

    /// G-5: one tick of steering. Updates the track's persistent velocity and
    /// facing, and returns the velocity as this tick's delta. See
    /// `SteerConfig` for the per-tick update order.
    fn apply_steer(&mut self, t_idx: usize, steer: &SteerConfig) -> Vec3 {
        // Snapshot (read-only borrows end before the writeback below).
        let (sx, sy) = (self.stick[0], self.stick[1]);
        let r = (sx * sx + sy * sy).sqrt().min(1.0);
        let yaw = self.tracks[t_idx].facing_yaw;
        let turn_vel = self.tracks[t_idx].turn_vel;
        let vel = self.tracks[t_idx].velocity;
        let stick_dir = if r > 1e-6 {
            Some(self.stick_world_dir())
        } else {
            None
        };
        let yr = yaw * PI / 180.0;
        let fwd = Vec3::new(yr.sin(), 0.0, yr.cos());
        let rightv = Vec3::new(yr.cos(), 0.0, -yr.sin());

        // Stick decomposed in the facing frame (sf forward+, ss right+),
        // signed amounts in [-1, 1].
        let (sf, ss) = match stick_dir {
            Some(d) => (d.dot(fwd) * r, d.dot(rightv) * r),
            None => (0.0, 0.0),
        };

        let mut vh = Vec3::new(vel.x, 0.0, vel.z);
        let mut vy = vel.y;
        let mut hspeed = vh.length();

        // --- horizontal accel below the cap, decel at/above it ---
        let cap = steer.speed_cap + steer.speed_cap_per_radius * r;
        if cap > 0.0 && hspeed >= cap {
            if steer.decel_above_cap > 0.0 && hspeed > cap {
                let ns = (hspeed - steer.decel_above_cap).max(cap);
                vh = vh * (ns / hspeed);
                hspeed = ns;
            }
        } else {
            let mut vf = vh.dot(fwd);
            let mut vs = vh.dot(rightv);
            vf += steer.accel_forward * sf.max(0.0);
            vs += steer.accel_side * ss;
            if sf < 0.0 && (!steer.backward_until_zero || vf > 0.0) {
                vf += steer.accel_backward * sf; // sf < 0 reduces vf
                if steer.backward_until_zero {
                    vf = vf.max(0.0);
                }
            }
            vh = fwd * vf + rightv * vs;
            if steer.accel_along_velocity > 0.0 && r > 1e-6 {
                hspeed = vh.length();
                if hspeed > 1e-6 {
                    vh = vh + vh.normalized() * (steer.accel_along_velocity * r);
                }
            }
            hspeed = vh.length();
        }

        // --- multiplicative decay, then hard clamp ---
        if steer.decay > 0.0 && steer.decay < 1.0 {
            vh = vh * (1.0 - steer.decay);
            hspeed = vh.length();
        }
        if steer.max_speed > 0.0 && hspeed > steer.max_speed {
            vh = vh * (steer.max_speed / hspeed);
            hspeed = steer.max_speed;
        }
        if steer.speed_min > 0.0 && hspeed < steer.speed_min {
            if hspeed > 1e-6 {
                vh = vh * (steer.speed_min / hspeed);
            } else {
                // No direction; push along facing.
                let f = facing_dir(self.tracks[t_idx].facing_yaw);
                vh = f * steer.speed_min;
            }
            hspeed = steer.speed_min;
        }

        // --- vertical ---
        if steer.gravity != 0.0 {
            vy -= steer.gravity;
            if steer.terminal_velocity > 0.0 {
                vy = vy.max(-steer.terminal_velocity);
            }
        }

        // --- facing ---
        let (new_facing, new_turn_vel) = match steer.face_mode {
            FaceMode::Keep => (yaw, turn_vel),
            FaceMode::Velocity => {
                if hspeed > 1e-6 {
                    (angle_of(vh), turn_vel)
                } else {
                    (yaw, turn_vel)
                }
            }
            FaceMode::Stick => match stick_dir {
                Some(d) => turn_step(yaw, turn_vel, angle_of(d), hspeed, r, steer),
                None => (yaw, 0.0),
            },
        };

        // --- writeback ---
        let t = &mut self.tracks[t_idx];
        t.velocity = Vec3::new(vh.x, vy, vh.z);
        t.facing_yaw = new_facing;
        t.turn_vel = new_turn_vel;
        t.velocity
    }

    fn resolve_direction(&mut self, t_idx: usize, mi: usize, si: usize) -> Vec3 {
        let st = &self.resolved.machines[mi].states[si];
        match st.direction_source {
            DirectionSource::Author => Vec3::from_array(st.direction).safe_normalized(),
            DirectionSource::Input => {
                let target = self.input_direction(st);
                let max_deg = st.input_turn_rate_deg;
                if max_deg <= 0.0 || target.is_zero() {
                    if !target.is_zero() {
                        self.tracks[t_idx].last_input_dir = target;
                    }
                    return target;
                }
                let prev = self.tracks[t_idx].last_input_dir;
                if prev.is_zero() {
                    self.tracks[t_idx].last_input_dir = target;
                    return target;
                }
                let angle = prev.angle_to(target);
                let max_a = max_deg * PI / 180.0;
                if angle <= max_a {
                    self.tracks[t_idx].last_input_dir = target;
                    return target;
                }
                let mut axis = prev.cross(target);
                if axis.length_squared() < 1e-6 {
                    axis = if st.input_plane == InputPlane::Xz {
                        UP
                    } else {
                        BACK
                    };
                } else {
                    axis = axis.normalized();
                }
                let nd = prev.rotated(axis, max_a);
                self.tracks[t_idx].last_input_dir = nd;
                nd
            }
            DirectionSource::Entry => {
                let t = &self.tracks[t_idx];
                if t.entry_motion.length_squared() > EPS * EPS {
                    t.entry_motion.normalized()
                } else {
                    Vec3::from_array(st.direction).safe_normalized()
                }
            }
            DirectionSource::ImpactNormal => {
                let t = &self.tracks[t_idx];
                if t.has_impact {
                    t.impact_normal.safe_normalized()
                } else {
                    Vec3::from_array(st.direction).safe_normalized()
                }
            }
            DirectionSource::Reflected => {
                let t = &self.tracks[t_idx];
                if t.has_impact {
                    if t.last_delta.length_squared() > EPS * EPS {
                        t.last_delta.bounce(t.impact_normal).safe_normalized()
                    } else {
                        t.impact_normal.safe_normalized()
                    }
                } else {
                    Vec3::from_array(st.direction).safe_normalized()
                }
            }
        }
    }

    fn input_direction(&self, st: &FrameState) -> Vec3 {
        let x = self.input.axis(&st.input_left, &st.input_right);
        let y = self.input.axis(&st.input_forward, &st.input_back);
        let len = (x * x + y * y).sqrt();
        if len < st.input_deadzone {
            return ZERO;
        }
        let nx = x / len;
        let ny = y / len;
        match st.input_plane {
            InputPlane::Xz => {
                let yaw = if st.camera_relative {
                    self.camera_yaw
                } else {
                    0.0
                };
                let (s, c) = yaw.sin_cos();
                let fwd = Vec3::new(-s, 0.0, -c);
                let right = Vec3::new(c, 0.0, -s);
                (right * nx + fwd * (-ny)).normalized()
            }
            InputPlane::Xy => Vec3::new(nx, ny, 0.0).normalized(),
        }
    }

    // ------------------------------------------------------------ collision

    fn track_collision(&mut self, t_idx: usize, contact: &ContactState) {
        let now = [contact.floor, contact.ceiling, contact.wall];
        let mut fired_kind: Option<usize> = None;
        for kind in [K_FLOOR, K_CEILING, K_WALL] {
            let is_now = now[kind];
            let was = self.tracks[t_idx].contact_prev[kind];
            if is_now && !was {
                let thr = self
                    .effective_response(t_idx, kind)
                    .map(|r| r.rearm_ticks)
                    .unwrap_or(DEFAULT_REARM_TICKS);
                let rearm = self.tracks[t_idx].rearm[kind];
                if rearm >= thr {
                    let name = match kind {
                        K_FLOOR => "floor_gained",
                        K_CEILING => "ceiling_gained",
                        _ => "wall_gained",
                    };
                    self.emit_event_now(name);
                    if fired_kind.is_none() {
                        fired_kind = Some(kind);
                    }
                    self.tracks[t_idx].rearm[kind] = 0;
                } else {
                    self.tracks[t_idx].rearm[kind] = rearm.saturating_add(1).min(99);
                }
            } else if !is_now && was {
                let name = match kind {
                    K_FLOOR => "floor_lost",
                    K_CEILING => "ceiling_lost",
                    _ => "wall_lost",
                };
                self.emit_event_now(name);
                let rearm = self.tracks[t_idx].rearm[kind];
                self.tracks[t_idx].rearm[kind] = rearm.saturating_add(1).min(99);
            } else {
                let rearm = self.tracks[t_idx].rearm[kind];
                self.tracks[t_idx].rearm[kind] = rearm.saturating_add(1).min(99);
            }
            self.tracks[t_idx].contact_prev[kind] = is_now;
        }
        if let Some(kind) = fired_kind {
            self.fire_response(t_idx, kind, contact);
        }
    }

    fn effective_response(&self, t_idx: usize, kind: usize) -> Option<ResolvedResp> {
        let t = &self.tracks[t_idx];
        let m = &self.resolved.machines[t.machine];
        if let Some(r) = &m.resp[t.current][kind] {
            return Some(r.clone());
        }
        m.default_resp[kind].clone()
    }

    fn fire_response(&mut self, t_idx: usize, kind: usize, contact: &ContactState) {
        let resp = match self.effective_response(t_idx, kind) {
            Some(r) => r,
            None => return,
        };
        let incoming_ups = self.tracks[t_idx].last_delta.length() * TICKS_PER_SECOND;
        if incoming_ups < resp.min_incoming_speed {
            return;
        }
        let n = match kind {
            K_FLOOR => contact.floor_normal,
            K_CEILING => contact.ceiling_normal,
            _ => contact.wall_normal,
        };
        let rate = self.tracks[t_idx].last_delta.length();
        if !resp.target_behavior.is_empty() {
            self.switch_impact = Some((n, rate));
            let name = resp.target_behavior.clone();
            self.switch_behavior(&name);
            return;
        }
        if let Some(tgt) = resp.target {
            self.enter_state(t_idx, tgt, None, n, rate, true);
        }
    }

    // ------------------------------------------------- behavior transitions

    fn behavior_transitions(&mut self) {
        let n_rows = self.resolved.behavior_transitions.len();
        for ri in 0..n_rows {
            let fire = {
                let row = &self.resolved.behavior_transitions[ri];
                self.condition_true(None, &row.cond)
            };
            if fire {
                let (fire_event, target_behavior) = {
                    let row = &self.resolved.behavior_transitions[ri];
                    (row.fire_event.clone(), row.target_behavior.clone())
                };
                if !fire_event.is_empty() {
                    self.push_event(&fire_event);
                }
                if !target_behavior.is_empty() && target_behavior != self.resolved.name {
                    self.switch_behavior(&target_behavior);
                }
                return;
            }
        }
    }

    fn advance_frame(&mut self, t_idx: usize) {
        {
            let t = &mut self.tracks[t_idx];
            if t.just_entered {
                t.just_entered = false;
                return;
            }
            if t.blend_left > 0 {
                t.blend_left -= 1;
            }
        }
        let (dur, _) = {
            let t = &self.tracks[t_idx];
            let m = &self.resolved.machines[t.machine];
            (m.states[t.current].duration_frames.max(1), ())
        };
        let t = &mut self.tracks[t_idx];
        t.frame += 1;
        if t.frame > dur {
            t.frame = dur;
        }
    }

    // ------------------------------------------------------------ inspection

    /// Current (machine, state, frame) per track — for tests/debug.
    pub fn track_states(&self) -> Vec<(String, String, u32)> {
        self.tracks
            .iter()
            .map(|t| {
                let m = &self.resolved.machines[t.machine];
                (
                    m.name.clone(),
                    m.states[t.current].state_name.clone(),
                    t.frame,
                )
            })
            .collect()
    }
}

// ---------------------------------------------------------------------------
// Param helpers (mirror GDScript Variant == / _is_numeric)

fn as_f64(v: &ParamValue) -> Option<f64> {
    match v {
        ParamValue::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        ParamValue::Int(i) => Some(*i as f64),
        ParamValue::Float(f) => Some(*f),
        ParamValue::Str(_) => None,
        ParamValue::Vec3(_) => None,
    }
}

fn strict_f64(v: &ParamValue) -> Option<f64> {
    match v {
        ParamValue::Int(i) => Some(*i as f64),
        ParamValue::Float(f) => Some(*f),
        _ => None,
    }
}

fn values_equal(a: &ParamValue, b: &ParamValue) -> bool {
    match (a, b) {
        (ParamValue::Bool(x), ParamValue::Bool(y)) => x == y,
        (ParamValue::Str(x), ParamValue::Str(y)) => x == y,
        (ParamValue::Vec3(x), ParamValue::Vec3(y)) => x == y,
        _ => match (as_f64(a), as_f64(b)) {
            (Some(x), Some(y)) => x == y,
            _ => false,
        },
    }
}

/// Shared comparison used by OnVariable (including the G-3 state_step param).
fn compare_param(op: &Op, a: &ParamValue, b: &ParamValue) -> bool {
    match op {
        Op::Eq => values_equal(a, b),
        Op::Ne => !values_equal(a, b),
        _ => {
            let (x, y) = match (strict_f64(a), strict_f64(b)) {
                (Some(x), Some(y)) => (x, y),
                _ => return false,
            };
            match op {
                Op::Gt => x > y,
                Op::Ge => x >= y,
                Op::Lt => x < y,
                Op::Le => x <= y,
                _ => false,
            }
        }
    }
}

/// Facing yaw (degrees) -> unit XZ vector. Inverse of `angle_of`.
fn facing_dir(yaw_deg: f32) -> Vec3 {
    let r = yaw_deg * PI / 180.0;
    Vec3::new(r.sin(), 0.0, r.cos())
}

/// Unit XZ vector -> yaw in degrees, consistent with `facing_dir`.
fn angle_of(v: Vec3) -> f32 {
    v.x.atan2(v.z) * 180.0 / PI
}

/// Signed angular difference a - b wrapped to (-180, 180] degrees.
fn ang_diff_deg(a: f32, b: f32) -> f32 {
    let mut d = (a - b) % 360.0;
    if d <= -180.0 {
        d += 360.0;
    } else if d > 180.0 {
        d -= 360.0;
    }
    d
}

fn move_toward(cur: f32, target: f32, max_delta: f32) -> f32 {
    let d = target - cur;
    if d.abs() <= max_delta {
        target
    } else {
        cur + max_delta * d.signum()
    }
}

/// G-5: one tick of the turn model toward `target` yaw. Returns the new
/// (facing yaw, angular velocity).
fn turn_step(
    yaw: f32,
    turn_vel: f32,
    target: f32,
    hspeed: f32,
    stick_radius: f32,
    steer: &SteerConfig,
) -> (f32, f32) {
    let tm = &steer.turn;
    let diff = ang_diff_deg(target, yaw);
    let adiff = diff.abs();
    if adiff <= tm.deadzone_deg {
        return (yaw, 0.0);
    }
    if tm.max_angle_deg > 0.0 && adiff > tm.max_angle_deg {
        return (yaw, turn_vel);
    }
    // Quickturn override: wide stick angles turn at a flat rate.
    if steer.quickturn_angle_deg > 0.0
        && steer.quickturn_rate_deg > 0.0
        && adiff >= steer.quickturn_angle_deg
    {
        let step = diff.clamp(-steer.quickturn_rate_deg, steer.quickturn_rate_deg);
        return (yaw + step, step);
    }
    // Speed-tiered turn cap; empty tiers mean uncapped.
    let mut cap = f32::MAX;
    for tier in &tm.tiers {
        if hspeed <= tier.speed_max {
            cap = tier.cap_base + tier.cap_per_speed * hspeed + tier.cap_per_radius * stick_radius;
            if tier.cap_min > 0.0 {
                cap = cap.max(tier.cap_min);
            }
            if tier.cap_max > 0.0 {
                cap = cap.min(tier.cap_max);
            }
            break;
        }
    }
    let desired = diff.clamp(-cap, cap);
    // No accel fractions configured -> snap to the capped rate.
    if tm.accel_near_frac <= 0.0 && tm.accel_far_frac <= 0.0 {
        return (yaw + desired, desired);
    }
    let frac = if adiff <= tm.far_angle_deg {
        tm.accel_near_frac
    } else {
        tm.accel_far_frac
    };
    let tv = move_toward(turn_vel, desired, frac * cap);
    // Never overshoot the target.
    let tv = if tv.abs() > adiff { diff } else { tv };
    (yaw + tv, tv)
}
