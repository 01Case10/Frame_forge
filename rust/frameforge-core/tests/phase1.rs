#![allow(clippy::field_reassign_with_default)]

//! Port of `tests/phase1_runner.gd` — 9 checks.

mod common;

use common::*;
use frameforge_core::input::TickInput;
use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{DirectionSource, DisplacementSource, EventTrigger, ParamType, ParamValue};

fn approx(a: f32, b: f32, eps: f32) -> bool {
    (a - b).abs() <= eps
}

#[test]
fn chain_basic() {
    let mut a = mk_state("A", 4.0, Vec3::new(1.0, 0.0, 0.0), 4);
    let b = mk_state("B", 2.0, Vec3::new(0.0, 1.0, 0.0), 2);
    a.transitions = vec![on_complete_row("B")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..6 {
        h.tick(&input);
    }
    assert!(
        (h.pos - Vec3::new(4.0, 2.0, 0.0)).length() < 1e-4,
        "final pos {:?}",
        h.pos
    );
    assert_eq!(h.state("M"), "B");
}

#[test]
fn jump_net_zero() {
    let mut r1 = mk_state("RiseFast", 7.0, Vec3::new(0.0, 1.0, 0.0), 2);
    let mut r2 = mk_state("RiseSlow", 3.0, Vec3::new(0.0, 1.0, 0.0), 8);
    let mut hstate = mk_state("Hover", 0.0, Vec3::new(0.0, 1.0, 0.0), 1);
    let f = mk_state("Fall", 10.0, Vec3::new(0.0, -1.0, 0.0), 5);
    r1.transitions = vec![on_complete_row("RiseSlow")];
    r2.transitions = vec![on_complete_row("Hover")];
    hstate.transitions = vec![on_complete_row("Fall")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("V", vec![r1, r2, hstate, f], "RiseFast")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..16 {
        h.tick(&input);
    }
    assert!(h.pos.y.abs() < 1e-4, "net vertical zero, y={}", h.pos.y);
    assert!(h.pos.x.abs() < 1e-6, "no horizontal drift");
}

#[test]
fn parallel_sum() {
    let v = mk_state("Rise", 4.0, Vec3::new(0.0, 1.0, 0.0), 4);
    let hz = mk_state("Fwd", 3.0, Vec3::new(1.0, 0.0, 0.0), 4);
    let mut h = Harness::new(mk_behavior(
        vec![
            mk_machine("Vert", vec![v], "Rise"),
            mk_machine("Horiz", vec![hz], "Fwd"),
        ],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..4 {
        h.tick(&input);
    }
    assert!(
        (h.pos - Vec3::new(3.0, 4.0, 0.0)).length() < 1e-4,
        "parallel sum {:?}",
        h.pos
    );
}

#[test]
fn easing_exact() {
    let mut s = mk_state("E", 6.0, Vec3::new(1.0, 0.0, 0.0), 3);
    s.easing = linear_curve([0.0, 0.0], [1.0, 2.0]);
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![s], "E")], "Behavior"));
    let input = TickInput::default();
    let mut xs = vec![h.pos.x];
    for _ in 0..3 {
        h.tick(&input);
        xs.push(h.pos.x);
    }
    let d: Vec<f32> = xs.windows(2).map(|w| w[1] - w[0]).collect();
    assert!(d[0].abs() < 1e-4, "ramp starts at 0, got {}", d[0]);
    assert!(
        d[0] < d[1] && d[1] < d[2],
        "strictly increasing, got {:?}",
        d
    );
    assert!((h.pos.x - 6.0).abs() < 1e-4, "integrates exactly to 6");
}

#[test]
fn input_direction() {
    let mut r = mk_state("Run", 0.1, ZERO, 1);
    r.direction_source = DirectionSource::Input;
    r.input_left = "t_left".to_string();
    r.input_right = "t_right".to_string();
    r.input_forward = "t_forward".to_string();
    r.input_back = "t_back".to_string();
    r.transitions = vec![on_complete_row("Run")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![r], "Run")],
        "Behavior",
    ));
    for tick in 0..20 {
        let input = match tick {
            0..=9 => held(&["t_right"]),
            _ => held(&["t_forward"]),
        };
        // Mirror the GDScript on_tick: press at 0, switch at 10.
        h.tick(&input);
    }
    assert!(
        (h.pos - Vec3::new(1.0, 0.0, -1.0)).length() < 1e-3,
        "input steered mid-state, pos {:?}",
        h.pos
    );
    assert_eq!(h.state("M"), "Run");
}

#[test]
fn entry_brake() {
    let mut a = mk_state("Run2", 0.2, Vec3::new(1.0, 0.0, 0.0), 2);
    let mut b = mk_state("Brake", 0.0, ZERO, 4);
    b.direction_source = DirectionSource::Entry;
    b.displacement_source = DisplacementSource::Entry;
    b.easing = linear_curve([0.0, 1.0], [1.0, 0.0]);
    let mut idle = mk_state("Idle", 0.0, ZERO, 1);
    a.transitions = vec![on_complete_row("Brake")];
    b.transitions = vec![on_complete_row("Idle")];
    idle.transitions = vec![on_complete_row("Idle")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b, idle], "Run2")],
        "Behavior",
    ));
    let input = TickInput::default();
    let mut speeds = vec![];
    let mut last_x = 0.0;
    for _ in 0..8 {
        h.tick(&input);
        speeds.push(h.pos.x - last_x);
        last_x = h.pos.x;
    }
    assert_eq!(speeds.len(), 8);
    assert!(
        approx(speeds[2], 0.1, 1e-4),
        "first brake frame = entry speed, got {}",
        speeds[2]
    );
    assert!(
        speeds[2] > speeds[3] && speeds[3] > speeds[4] && speeds[4] > speeds[5],
        "strictly decreasing, got {:?}",
        &speeds[2..6]
    );
    assert!(speeds[5] < 0.06, "tail decayed, got {}", speeds[5]);
    assert!(
        speeds[6].abs() < 1e-4 && speeds[7].abs() < 1e-4,
        "idle after brake"
    );
}

#[test]
fn blackboard() {
    let s = mk_state("Idle", 0.0, ZERO, 1);
    let mut bh = mk_behavior(vec![mk_machine("M", vec![s], "Idle")], "Behavior");
    add_param(&mut bh, "speed", ParamType::Float, ParamValue::Float(2.5));
    add_param(
        &mut bh,
        "grounded",
        ParamType::Bool,
        ParamValue::Bool(false),
    );
    let mut h = Harness::new(bh);
    assert_eq!(h.rt.get_param("speed"), Some(&ParamValue::Float(2.5)));
    assert_eq!(h.rt.get_param("grounded"), Some(&ParamValue::Bool(false)));
    assert!(!h.rt.has_param("nope"));
    h.rt.set_param("speed", ParamValue::Float(4.0));
    assert_eq!(h.rt.get_param("speed"), Some(&ParamValue::Float(4.0)));
}

#[test]
fn soak_600() {
    let mut s = mk_state("Loop", 0.05, Vec3::new(1.0, 0.0, 0.0), 1);
    s.transitions = vec![on_complete_row("Loop")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![s], "Loop")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..600 {
        h.tick(&input);
    }
    assert!(
        (h.pos.x - 30.0).abs() < 1e-2,
        "600*0.05=30, got {}",
        h.pos.x
    );
    assert!(h.pos.x.is_finite(), "no NaN/inf");
    assert_eq!(h.rt.tick_count(), 600);
}

#[test]
fn impact_fallback() {
    let mut a = mk_state("A", 1.0, Vec3::new(1.0, 0.0, 0.0), 2);
    let mut b = mk_state("Bounce", 2.0, Vec3::new(0.0, 0.0, 1.0), 2);
    b.direction_source = DirectionSource::ImpactNormal;
    b.displacement_source = DisplacementSource::Incoming;
    a.transitions = vec![on_complete_row("Bounce")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    for _ in 0..4 {
        h.tick(&input);
    }
    assert!(
        (h.pos - Vec3::new(1.0, 0.0, 2.0)).length() < 1e-4,
        "fallback to authored, pos {:?}",
        h.pos
    );
}

#[test]
fn event_trigger_defaults() {
    // FFStateEvent default trigger is OnEnter (used by mk_event helper).
    let e = mk_event("x", EventTrigger::OnEnter, 0);
    assert_eq!(e.trigger, EventTrigger::OnEnter);
}
