//! Phase 7 (G-6): trait-based state logic — validation, lifecycle, and the
//! three built-in logics (wallrun, ledgegrab, poleclimb).
//!
//! Behavior tests assert PHYSICAL OUTCOMES via the harness's accumulated
//! `pos`, not just event logs: the player actually moves along the wall,
//! actually hangs on the ledge without falling, actually climbs the pole.

#![allow(clippy::field_reassign_with_default)]

mod common;

use common::*;
use frameforge_core::input::TickInput;
use frameforge_core::logic::{StateCtx, StateLogic};
use frameforge_core::tick::ContactState;
use frameforge_core::validate::{validate_behavior, Severity};
use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{
    InputMode, Momentum, ParamValue, SteerConfig, Transition,
};
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

fn approx(a: f32, b: f32, eps: f32) -> bool {
    (a - b).abs() <= eps
}

fn press(actions: &[&str]) -> TickInput {
    let mut held = HashSet::new();
    for a in actions {
        held.insert(a.to_string());
    }
    TickInput {
        held,
        strengths: HashMap::new(),
    }
}

fn release() -> TickInput {
    TickInput::default()
}

/// Tick with an explicit contact state (the game supplies contact, D3/D9).
fn tick_with(h: &mut Harness, input: &TickInput, contact: &ContactState) -> Vec3 {
    let d = h.rt.tick_delta(input);
    h.pos = h.pos + d;
    h.rt.tick_contact(contact);
    d
}

fn wall_contact() -> ContactState {
    let mut c = ContactState::default();
    c.wall = true;
    c.wall_normal = Vec3::new(-1.0, 0.0, 0.0);
    c
}

fn event_fired(h: &Harness, name: &str) -> bool {
    h.rt.event_log.iter().any(|e| e == name)
}

// ---------------------------------------------------------------------------
// 1. Validation
// ---------------------------------------------------------------------------

#[test]
fn validation_rejects_unknown_logic_and_warns_on_steer_conflict() {
    // Unknown logic name -> hard error.
    let mut s = mk_state("A", 0.0, ZERO, 10);
    s.logic = Some("nope".to_string());
    s.transitions = vec![on_complete_row("A")];
    let bh = mk_behavior(vec![mk_machine("M", vec![s], "A")], "T");
    let issues = validate_behavior(&bh);
    assert!(
        issues.iter().any(|i| i.severity == Severity::Error
            && i.message.contains("unknown state logic")),
        "expected unknown-logic error, got: {issues:?}"
    );

    // All three built-ins validate clean.
    for name in ["wallrun", "ledgegrab", "poleclimb"] {
        let mut s = mk_state("A", 0.0, ZERO, 10);
        s.logic = Some(name.to_string());
        s.transitions = vec![on_complete_row("A")];
        let bh = mk_behavior(vec![mk_machine("M", vec![s], "A")], "T");
        let issues = validate_behavior(&bh);
        assert!(
            !issues
                .iter()
                .any(|i| i.message.contains("unknown state logic")),
            "{name} should validate, got: {issues:?}"
        );
    }

    // steer + logic -> warning.
    let mut s = mk_state("A", 0.0, ZERO, 10);
    s.logic = Some("wallrun".to_string());
    s.steer = Some(SteerConfig::default());
    s.transitions = vec![on_complete_row("A")];
    let bh = mk_behavior(vec![mk_machine("M", vec![s], "A")], "T");
    let issues = validate_behavior(&bh);
    assert!(
        issues.iter().any(|i| i.severity == Severity::Warning
            && i.message.contains("both `steer` and `logic`")),
        "expected steer+logic warning, got: {issues:?}"
    );
}

// ---------------------------------------------------------------------------
// Wallrun behavior builders
// ---------------------------------------------------------------------------

fn wallrun_behavior() -> frameforge_core::FrameBehavior {
    let mut idle = mk_state("Idle", 0.0, ZERO, 1000);
    idle.transitions = vec![row_to(
        c_input(&["jump"], InputMode::AnyPressed),
        "Run",
        Momentum::Cut,
        0,
    )];
    let mut run = mk_state("Run", 0.0, ZERO, 1000);
    run.logic = Some("wallrun".to_string());
    run.transitions = vec![row_to(c_event("wallrun_end"), "Idle", Momentum::Cut, 0)];
    mk_behavior(vec![mk_machine("M", vec![idle, run], "Idle")], "WR")
}

/// Prime wall contact and enter the wallrun state; returns the harness
/// positioned at the start of the run.
fn enter_wallrun() -> Harness {
    let mut h = Harness::new(wallrun_behavior());
    tick_with(&mut h, &release(), &wall_contact());
    tick_with(&mut h, &release(), &wall_contact());
    tick_with(&mut h, &press(&["jump"]), &wall_contact());
    assert_eq!(h.state("M"), "Run");
    h
}

// ---------------------------------------------------------------------------
// 2. Wallrun traversal (outcome)
// ---------------------------------------------------------------------------

#[test]
fn wallrun_actually_moves_along_wall() {
    let mut h = enter_wallrun();
    // 30 more ticks pressed against the wall.
    for _ in 0..30 {
        tick_with(&mut h, &release(), &wall_contact());
    }
    // 31 running ticks total (entry + 30): along-wall +z at 0.15/tick,
    // into-wall stick +x at 0.02/tick, no vertical motion (no falling).
    assert!(approx(h.pos.z, 0.15 * 31.0, 1e-3), "pos.z = {}", h.pos.z);
    assert!(approx(h.pos.y, 0.0, 1e-6), "pos.y = {}", h.pos.y);
    assert!(approx(h.pos.x, 0.02 * 31.0, 1e-3), "pos.x = {}", h.pos.x);
    assert_eq!(h.state("M"), "Run", "still running (45-tick budget)");
}

// ---------------------------------------------------------------------------
// 3. Wallrun exits
// ---------------------------------------------------------------------------

#[test]
fn wallrun_exits_when_wall_lost() {
    let mut h = enter_wallrun();
    tick_with(&mut h, &release(), &wall_contact());
    // Wall lost. D3: the logic reads LAST tick's contact, so the loss
    // registers one tick late; the authored transition leaves a tick after
    // the event fires.
    tick_with(&mut h, &release(), &ContactState::default());
    tick_with(&mut h, &release(), &ContactState::default());
    assert!(event_fired(&h, "wallrun_end"), "wallrun_end fired");
    tick_with(&mut h, &release(), &ContactState::default());
    assert_eq!(h.state("M"), "Idle", "transitioned out");
}

#[test]
fn wallrun_timer_expires() {
    let mut h = Harness::new(wallrun_behavior());
    // Budget must be set before entry: on_enter reads it.
    h.rt.set_param("wallrun_max_ticks", ParamValue::Float(5.0));
    tick_with(&mut h, &release(), &wall_contact());
    tick_with(&mut h, &release(), &wall_contact());
    tick_with(&mut h, &press(&["jump"]), &wall_contact());
    assert_eq!(h.state("M"), "Run");
    // 5 running ticks (entry + 4); wallrun_end fires on the 6th on_tick.
    for _ in 0..4 {
        tick_with(&mut h, &release(), &wall_contact());
        assert!(!event_fired(&h, "wallrun_end"), "budget not yet exhausted");
    }
    tick_with(&mut h, &release(), &wall_contact());
    assert!(event_fired(&h, "wallrun_end"), "budget exhausted");
    assert_eq!(h.state("M"), "Run", "transition leaves next tick");
    tick_with(&mut h, &release(), &wall_contact());
    assert_eq!(h.state("M"), "Idle");
}

#[test]
fn wallrun_tagged_wall_ends_run() {
    let mut h = enter_wallrun();
    // The game tags the touched wall non-runnable (its `no_wallrun` group)
    // and maps it to the param; the logic ends the run mid-stride.
    h.rt.set_param("wallrun.available", ParamValue::Bool(false));
    tick_with(&mut h, &release(), &wall_contact());
    assert!(event_fired(&h, "wallrun_end"), "tagged wall ends the run");
    tick_with(&mut h, &release(), &wall_contact());
    assert_eq!(h.state("M"), "Idle", "transitioned out");
}

// ---------------------------------------------------------------------------
// 8. Moving wall carry
// ---------------------------------------------------------------------------

#[test]
fn wallrun_moving_wall_carries_player() {
    let mut c = wall_contact();
    c.wall_velocity = Vec3::new(3.0, 0.0, 0.0); // 3 u/s -> 0.05/tick
    let mut h = Harness::new(wallrun_behavior());
    tick_with(&mut h, &release(), &c);
    tick_with(&mut h, &release(), &c);
    let d = tick_with(&mut h, &press(&["jump"]), &c);
    // Entry tick delta: into-wall stick 0.02 + carry 0.05 on x, 0.15 on z.
    assert!(approx(d.x, 0.07, 1e-4), "delta.x = {}", d.x);
    assert!(approx(d.z, 0.15, 1e-4), "delta.z = {}", d.z);
    assert!(approx(d.y, 0.0, 1e-6), "delta.y = {}", d.y);
}

#[test]
fn wallrun_zero_velocity_matches_static() {
    let run = |contact: ContactState| -> Vec3 {
        let mut h = Harness::new(wallrun_behavior());
        tick_with(&mut h, &release(), &contact);
        tick_with(&mut h, &release(), &contact);
        tick_with(&mut h, &press(&["jump"]), &contact);
        for _ in 0..10 {
            tick_with(&mut h, &release(), &contact);
        }
        h.pos
    };
    let a = run(wall_contact());
    let mut explicit_zero = wall_contact();
    explicit_zero.wall_velocity = ZERO;
    let b = run(explicit_zero);
    assert_eq!(a, b, "zero velocity == static path");
}

// ---------------------------------------------------------------------------
// 4. Ledgegrab hold (outcome)
// ---------------------------------------------------------------------------

fn ledgegrab_behavior() -> frameforge_core::FrameBehavior {
    let mut fall = mk_state("Fall", 0.0, ZERO, 1000);
    fall.transitions = vec![row_to(
        c_input(&["grab"], InputMode::AnyPressed),
        "Hang",
        Momentum::Cut,
        0,
    )];
    let mut hang = mk_state("Hang", 0.0, ZERO, 1000);
    hang.logic = Some("ledgegrab".to_string());
    hang.transitions = vec![
        row_to(c_event("ledgegrab_climb"), "Top", Momentum::Cut, 0),
        row_to(c_event("ledgegrab_drop"), "Fall", Momentum::Cut, 0),
    ];
    let mut top = mk_state("Top", 2.0, Vec3::new(0.0, 1.0, 0.0), 10);
    top.transitions = vec![on_complete_row("Fall")];
    mk_behavior(vec![mk_machine("M", vec![fall, hang, top], "Fall")], "LG")
}

fn enter_ledgegrab() -> Harness {
    let mut h = Harness::new(ledgegrab_behavior());
    h.rt.set_param(
        "ledgegrab.offset",
        ParamValue::Vec3([0.5, 1.0, 0.0]),
    );
    tick_with(&mut h, &release(), &wall_contact());
    tick_with(&mut h, &release(), &wall_contact());
    tick_with(&mut h, &press(&["grab"]), &wall_contact());
    assert_eq!(h.state("M"), "Hang");
    h
}

#[test]
fn ledgegrab_snaps_and_hangs_without_falling() {
    let mut h = enter_ledgegrab();
    // The snap landed (entry tick applied the offset).
    assert!(
        approx(h.pos.x, 0.5, 1e-6) && approx(h.pos.y, 1.0, 1e-6),
        "pos after snap = {:?}",
        h.pos
    );
    // The offset was consumed (one-shot).
    assert_eq!(
        h.rt.get_param("ledgegrab.offset"),
        Some(&ParamValue::Vec3([0.0, 0.0, 0.0])),
        "offset zeroed after enter"
    );
    // 60 idle ticks: the player hangs — pos does not change at all.
    let before = h.pos;
    for _ in 0..60 {
        tick_with(&mut h, &release(), &wall_contact());
    }
    assert_eq!(h.pos, before, "hanging: no drift, no fall");
    // Jump climbs: authored Top state raises the player above the ledge.
    tick_with(&mut h, &press(&["jump"]), &wall_contact());
    assert!(event_fired(&h, "ledgegrab_climb"));
    for _ in 0..12 {
        tick_with(&mut h, &release(), &wall_contact());
    }
    assert!(
        h.pos.y > 2.0,
        "climbed above the ledge, pos.y = {}",
        h.pos.y
    );
}

#[test]
fn ledgegrab_drops_on_wall_loss() {
    let mut h = enter_ledgegrab();
    // D3: one staleness tick before the logic sees the wall is gone.
    tick_with(&mut h, &release(), &ContactState::default());
    tick_with(&mut h, &release(), &ContactState::default());
    assert!(event_fired(&h, "ledgegrab_drop"));
    tick_with(&mut h, &release(), &ContactState::default());
    assert_eq!(h.state("M"), "Fall");
}

#[test]
fn ledgegrab_stick_toward_wall_climbs_after_10_ticks() {
    let mut h = enter_ledgegrab();
    // Stick toward the wall (+x, against the -x normal), camera yaw 0.
    h.rt.set_stick(1.0, 0.0);
    for _ in 0..9 {
        tick_with(&mut h, &release(), &wall_contact());
        assert!(!event_fired(&h, "ledgegrab_climb"), "no early climb");
    }
    tick_with(&mut h, &release(), &wall_contact());
    assert!(event_fired(&h, "ledgegrab_climb"), "climb on the 10th tick");
}

// ---------------------------------------------------------------------------
// 5. Poleclimb ascent (outcome)
// ---------------------------------------------------------------------------

fn poleclimb_behavior() -> frameforge_core::FrameBehavior {
    let mut idle = mk_state("Idle", 0.0, ZERO, 1000);
    idle.transitions = vec![row_to(
        c_input(&["grab"], InputMode::AnyPressed),
        "Pole",
        Momentum::Cut,
        0,
    )];
    let mut pole = mk_state("Pole", 0.0, ZERO, 1000);
    pole.logic = Some("poleclimb".to_string());
    pole.transitions = vec![
        row_to(c_event("poleclimb_jump"), "Leap", Momentum::Cut, 0),
        row_to(c_event("poleclimb_drop"), "Idle", Momentum::Cut, 0),
        row_to(c_event("poleclimb_top"), "Mount", Momentum::Cut, 0),
    ];
    let mut leap = mk_state("Leap", 1.0, Vec3::new(1.0, 0.0, 0.0), 10);
    leap.transitions = vec![on_complete_row("Idle")];
    let mut mount = mk_state("Mount", 0.0, ZERO, 10);
    mount.transitions = vec![on_complete_row("Idle")];
    mk_behavior(
        vec![mk_machine("M", vec![idle, pole, leap, mount], "Idle")],
        "PC",
    )
}

const POLE_AXIS: (f32, f32) = (1.0, 0.0); // x, z

/// Enter the pole state. The pole axis is at (1, 0); the game-supplied
/// snap takes the player from (0,0,0) to the grab pose (1, 0.5, 0).
fn enter_poleclimb() -> Harness {
    let mut h = Harness::new(poleclimb_behavior());
    h.rt.set_param("poleclimb.snap", ParamValue::Vec3([1.0, 0.5, 0.0]));
    h.rt
        .set_param("poleclimb.available", ParamValue::Bool(true));
    h.rt.set_param(
        "poleclimb.recenter",
        ParamValue::Vec3([POLE_AXIS.0, 0.0, POLE_AXIS.1]),
    );
    tick_with(&mut h, &release(), &ContactState::default());
    tick_with(&mut h, &press(&["grab"]), &ContactState::default());
    assert_eq!(h.state("M"), "Pole");
    h
}

/// One climb tick, playing the game's role: refresh `recenter` from the
/// known pole position, like the real game loop does (D9).
fn pole_tick(h: &mut Harness, input: &TickInput, sy: f32) {
    let r = Vec3::new(POLE_AXIS.0 - h.pos.x, 0.0, POLE_AXIS.1 - h.pos.z);
    h.rt.set_param("poleclimb.recenter", ParamValue::Vec3(r.to_array()));
    h.rt.set_stick(0.0, sy);
    tick_with(h, input, &ContactState::default());
}

#[test]
fn poleclimb_actually_climbs_the_pole() {
    let mut h = enter_poleclimb();
    // Snap landed at the grab pose.
    assert!(
        approx(h.pos.x, 1.0, 1e-6) && approx(h.pos.y, 0.5, 1e-6),
        "pos after snap = {:?}",
        h.pos
    );
    // 60 ticks of stick-up: the pole is actually climbed at 0.05/tick
    // while staying glued to the axis.
    for _ in 0..60 {
        pole_tick(&mut h, &release(), 1.0);
    }
    assert!(approx(h.pos.y, 0.5 + 0.05 * 60.0, 1e-3), "pos.y = {}", h.pos.y);
    let dx = h.pos.x - POLE_AXIS.0;
    let dz = h.pos.z - POLE_AXIS.1;
    assert!(
        (dx * dx + dz * dz).sqrt() < 1e-3,
        "stayed on the axis, pos = {:?}",
        h.pos
    );
    // Jump leaps off.
    pole_tick(&mut h, &press(&["jump"]), 0.0);
    assert!(event_fired(&h, "poleclimb_jump"));
    pole_tick(&mut h, &release(), 0.0);
    assert_eq!(h.state("M"), "Leap");
}

#[test]
fn poleclimb_top_mounts() {
    let mut h = enter_poleclimb();
    for _ in 0..5 {
        pole_tick(&mut h, &release(), 1.0);
    }
    h.rt.set_param("poleclimb.top", ParamValue::Bool(true));
    pole_tick(&mut h, &release(), 1.0);
    assert!(event_fired(&h, "poleclimb_top"));
}

#[test]
fn poleclimb_drops_when_pole_lost() {
    let mut h = enter_poleclimb();
    h.rt
        .set_param("poleclimb.available", ParamValue::Bool(false));
    pole_tick(&mut h, &release(), 0.0);
    assert!(event_fired(&h, "poleclimb_drop"));
}

// ---------------------------------------------------------------------------
// 6. Lifecycle (probe logic with call counters)
// ---------------------------------------------------------------------------

struct Probe {
    enters: Rc<Cell<u32>>,
    ticks: Rc<Cell<u32>>,
    exits: Rc<Cell<u32>>,
    drops: Rc<Cell<u32>>,
}

impl StateLogic for Probe {
    fn on_enter(&mut self, _ctx: &mut StateCtx) {
        self.enters.set(self.enters.get() + 1);
    }
    fn on_tick(&mut self, _ctx: &mut StateCtx) {
        self.ticks.set(self.ticks.get() + 1);
    }
    fn on_exit(&mut self, _ctx: &mut StateCtx) {
        self.exits.set(self.exits.get() + 1);
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        self.drops.set(self.drops.get() + 1);
    }
}

#[test]
fn lifecycle_enter_exit_once_and_silent_self_skips() {
    let enters = Rc::new(Cell::new(0u32));
    let ticks = Rc::new(Cell::new(0u32));
    let exits = Rc::new(Cell::new(0u32));
    let drops = Rc::new(Cell::new(0u32));

    let mut a = mk_state("A", 0.0, ZERO, 1000);
    a.logic = Some("probe".to_string());
    let mut silent_self = row_to(
        c_input(&["selfx"], InputMode::AnyPressed),
        "A",
        Momentum::Cut,
        0,
    );
    silent_self.silent = true;
    a.transitions = vec![
        silent_self,
        row_to(c_input(&["go"], InputMode::AnyPressed), "B", Momentum::Cut, 0),
    ];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    b.transitions = vec![row_to(
        c_input(&["back"], InputMode::AnyPressed),
        "A",
        Momentum::Cut,
        0,
    )];
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Life");
    // Behavior switch target for the drop check.
    let other = mk_behavior(
        vec![mk_machine("M", vec![mk_state("Z", 0.0, ZERO, 1000)], "Z")],
        "Other",
    );
    let mut sw = Transition::default();
    sw.condition = c_input(&["switch"], InputMode::AnyPressed);
    sw.target_behavior_name = "Other".to_string();
    bh.behavior_transitions.push(sw);

    let mut h = Harness::new(bh);
    h.rt.register_behavior(other);
    let (e, t, x, d) = (
        Rc::clone(&enters),
        Rc::clone(&ticks),
        Rc::clone(&exits),
        Rc::clone(&drops),
    );
    h.rt.register_state_logic(
        "probe",
        Box::new(move || {
            Box::new(Probe {
                enters: Rc::clone(&e),
                ticks: Rc::clone(&t),
                exits: Rc::clone(&x),
                drops: Rc::clone(&d),
            }) as Box<dyn StateLogic>
        }),
    );

    // Late registration entered the entry state exactly once.
    assert_eq!(enters.get(), 1, "on_enter once (entry state)");
    h.tick(&release());
    h.tick(&release());
    assert_eq!(ticks.get(), 2, "on_tick per tick");

    // Silent self-transition: no exit, no re-enter, same instance.
    h.tick(&press(&["selfx"]));
    assert_eq!(enters.get(), 1, "silent self skips on_enter");
    assert_eq!(exits.get(), 0, "silent self skips on_exit");
    assert_eq!(drops.get(), 0, "instance persists");

    // Real exit: exactly one on_exit + drop.
    h.tick(&press(&["go"]));
    assert_eq!(h.state("M"), "B");
    assert_eq!(exits.get(), 1, "on_exit once");
    assert_eq!(drops.get(), 1, "instance dropped on exit");

    // Re-enter, then behavior switch drops it too.
    h.tick(&press(&["back"]));
    assert_eq!(enters.get(), 2, "on_enter again");
    h.tick(&press(&["switch"]));
    assert_eq!(h.rt.behavior_name(), "Other");
    assert_eq!(exits.get(), 2, "on_exit on behavior switch");
    assert_eq!(drops.get(), 2, "instance dropped on behavior switch");
}

// ---------------------------------------------------------------------------
// Runtime robustness: unregistered logic never panics
// ---------------------------------------------------------------------------

#[test]
fn unregistered_logic_behaves_as_data_state() {
    let mut s = mk_state("X", 1.0, Vec3::new(1.0, 0.0, 0.0), 100);
    s.logic = Some("nope".to_string());
    s.transitions = vec![on_complete_row("X")];
    let bh = mk_behavior(vec![mk_machine("M", vec![s], "X")], "T");
    let mut h = Harness::new(bh);
    for _ in 0..10 {
        h.tick(&release());
    }
    assert!(h.pos.x > 0.0, "authored delta still applies, pos = {:?}", h.pos);
}

// ---------------------------------------------------------------------------
// 7. Determinism
// ---------------------------------------------------------------------------

#[test]
fn logic_runs_are_bit_identical() {
    let script = |h: &mut Harness| {
        tick_with(h, &release(), &wall_contact());
        tick_with(h, &release(), &wall_contact());
        tick_with(h, &press(&["jump"]), &wall_contact());
        for _ in 0..20 {
            tick_with(h, &release(), &wall_contact());
        }
        tick_with(h, &release(), &ContactState::default());
        tick_with(h, &release(), &ContactState::default());
    };
    let mut h1 = Harness::new(wallrun_behavior());
    let mut h2 = Harness::new(wallrun_behavior());
    script(&mut h1);
    script(&mut h2);
    assert_eq!(h1.pos, h2.pos, "identical positions");
    assert_eq!(h1.rt.event_log, h2.rt.event_log, "identical event logs");
}
