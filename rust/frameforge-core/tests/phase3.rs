#![allow(clippy::field_reassign_with_default)]

//! Port of `tests/phase3_runner.gd` — 8 checks.

mod common;

use common::*;
use frameforge_core::input::TickInput;
use frameforge_core::tick::Runtime;
use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{EventTrigger, FrameState, InputMode, Momentum, Op};

#[test]
fn signals_basic() {
    let mut a = mk_state("A", 0.0, ZERO, 2);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.transitions = vec![on_complete_row("B")];
    let mut bs = on_complete_row("B");
    bs.silent = true;
    b.transitions = vec![bs];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..4 {
        h.tick(&input);
    }
    assert_eq!(
        h.rt.signal_log,
        vec!["exit Behavior/M/A", "enter Behavior/M/B"],
        "got {:?}",
        h.rt.signal_log
    );
}

#[test]
fn signals_silent_selfloop() {
    let mut a = mk_state("A", 0.0, ZERO, 1);
    let mut r = on_complete_row("A");
    r.silent = true;
    a.transitions = vec![r];
    a.events = vec![
        mk_event("tick", EventTrigger::OnFrame, 0),
        mk_event("enter_a", EventTrigger::OnEnter, 0),
    ];
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a], "A")], "Behavior"));
    let input = TickInput::default();
    for _ in 0..4 {
        h.tick(&input);
    }
    assert!(h.rt.signal_log.is_empty(), "got {:?}", h.rt.signal_log);
    assert_eq!(
        h.rt.event_log
            .iter()
            .filter(|e| e.as_str() == "tick")
            .count(),
        4,
        "got {:?}",
        h.rt.event_log
    );
    assert!(!h.rt.event_log.contains(&"enter_a".to_string()));
}

#[test]
fn signals_loud_selfloop() {
    let mut a = mk_state("A", 0.0, ZERO, 1);
    a.transitions = vec![on_complete_row("A")];
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a], "A")], "Behavior"));
    let input = TickInput::default();
    for _ in 0..3 {
        h.tick(&input);
    }
    assert_eq!(
        h.rt.signal_log,
        vec![
            "exit Behavior/M/A",
            "enter Behavior/M/A",
            "exit Behavior/M/A",
            "enter Behavior/M/A"
        ],
        "got {:?}",
        h.rt.signal_log
    );
}

#[test]
fn signals_behavior_changed() {
    let mut idle_a = mk_state("IdleA", 0.0, ZERO, 1);
    let mut ia = on_complete_row("IdleA");
    ia.silent = true;
    idle_a.transitions = vec![ia];
    let mut fall_b = mk_state("FallB", 0.0, ZERO, 1);
    let mut fb = on_complete_row("FallB");
    fb.silent = true;
    fall_b.transitions = vec![fb];
    let mut ground = mk_behavior(vec![mk_machine("M", vec![idle_a], "IdleA")], "Ground");
    let air = mk_behavior(vec![mk_machine("M", vec![fall_b], "FallB")], "Air");
    let mut r = frameforge_core::Transition::default();
    r.condition = c_input(&["t_jump"], InputMode::AnyPressed);
    r.target_behavior_name = "Air".to_string();
    ground.behavior_transitions.push(r);
    ground.on_exit_event = "ground_bye".to_string();
    let mut air_reg = air.clone();
    air_reg.on_enter_event = "air_hi".to_string();
    let mut rt = Runtime::new(ground);
    rt.register_behavior(air_reg);
    let mut h = Harness { rt, pos: ZERO };
    for tick in 0..5 {
        let input = if tick == 2 {
            held(&["t_jump"])
        } else {
            TickInput::default()
        };
        h.tick(&input);
    }
    assert_eq!(
        h.rt.signal_log,
        vec![
            "exit Ground/M/IdleA",
            "behavior Ground->Air",
            "enter Air/M/FallB"
        ],
        "got {:?}",
        h.rt.signal_log
    );
    assert_eq!(
        h.rt.event_log,
        vec!["ground_bye", "air_hi"],
        "got {:?}",
        h.rt.event_log
    );
}

#[test]
fn signals_transition_event() {
    let mut a = mk_state("A", 0.0, ZERO, 2);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    let mut r = on_complete_row("B");
    r.fire_event = "jumped".to_string();
    a.transitions = vec![r];
    b.transitions = vec![on_complete_row("B")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..4 {
        h.tick(&input);
    }
    assert_eq!(h.rt.event_log, vec!["jumped"], "got {:?}", h.rt.event_log);
}

#[test]
fn signals_contact_event() {
    let mut fall = mk_state("Fall", 0.15, Vec3::new(0.0, -1.0, 0.0), 1);
    fall.transitions = vec![on_complete_row("Fall")];
    let mut land = mk_state("Land", 0.0, ZERO, 2);
    land.transitions = vec![on_complete_row("Land")];
    let mut m = mk_machine("M", vec![fall, land], "Fall");
    m.default_resp_floor = Some(mk_resp("Land", 0.0, 3));
    let mut h = Harness::new_at(mk_behavior(vec![m], "Behavior"), Vec3::new(0.0, 3.0, 0.0));
    let input = TickInput::default();
    for _ in 0..20 {
        h.tick_physics(&input);
    }
    assert!(
        h.rt.event_log.contains(&"floor_gained".to_string()),
        "got {:?}",
        h.rt.event_log
    );
}

#[test]
fn signals_frame_n_event() {
    let mut a = mk_state("A", 0.0, ZERO, 3);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.events = vec![
        mk_event("mid", EventTrigger::OnFrame, 1),
        mk_event("never", EventTrigger::OnFrame, 5),
    ];
    a.transitions = vec![on_complete_row("B")];
    b.transitions = vec![on_complete_row("B")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..5 {
        h.tick(&input);
    }
    assert_eq!(h.rt.event_log, vec!["mid"], "got {:?}", h.rt.event_log);
}

#[test]
fn signals_enter_exit_events() {
    let mut a = mk_state("A", 0.0, ZERO, 2);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.events = vec![
        mk_event("a_enter", EventTrigger::OnEnter, 0),
        mk_event("a_exit", EventTrigger::OnExit, 0),
    ];
    b.events = vec![mk_event("b_enter", EventTrigger::OnEnter, 0)];
    a.transitions = vec![on_complete_row("B")];
    let mut bs = on_complete_row("B");
    bs.silent = true;
    b.transitions = vec![bs];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..4 {
        h.tick(&input);
    }
    assert_eq!(
        h.rt.event_log,
        vec!["a_exit", "b_enter"],
        "got {:?}",
        h.rt.event_log
    );
}

// Silence unused-import warnings for items used only via common.
#[allow(dead_code)]
fn _use_imports() {
    let _ = (Momentum::Cut, Op::Eq, FrameState::default());
}
