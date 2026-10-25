#![allow(clippy::field_reassign_with_default)]

//! Port of `tests/phase2_runner.gd` — 18 checks.

mod common;

use common::*;
use frameforge_core::input::TickInput;
use frameforge_core::tick::Runtime;
use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{
    DirectionSource, DisplacementSource, InputMode, Momentum, Op, ParamType, ParamValue,
};
use std::cell::Cell;
use std::rc::Rc;

fn approx(a: f32, b: f32, eps: f32) -> bool {
    (a - b).abs() <= eps
}

#[test]
fn cond_priority() {
    let mut a = mk_state("A", 0.0, ZERO, 3);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    let c = mk_state("C", 0.0, ZERO, 1);
    b.transitions = vec![on_complete_row("B")];
    a.transitions = vec![
        row_to(
            c_var("go", Op::Eq, ParamValue::Bool(true)),
            "B",
            Momentum::Cut,
            3,
        ),
        on_complete_row("C"),
    ];
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b, c], "A")], "Behavior");
    add_param(&mut bh, "go", ParamType::Bool, ParamValue::Bool(false));
    let mut h = Harness::new(bh);
    let input = TickInput::default();
    let mut states = vec![];
    for tick in 0..4 {
        if tick == 2 {
            h.rt.set_param("go", ParamValue::Bool(true));
        }
        h.tick(&input);
        states.push(h.state("M"));
    }
    assert_eq!(states[0], "A");
    assert_eq!(states[1], "A");
    assert_eq!(states[2], "B", "variable row wins, got {:?}", states);
    assert!(!states.contains(&"C".to_string()), "C never entered");
}

#[test]
fn cond_priority_fallthrough() {
    let mut a = mk_state("A", 0.0, ZERO, 3);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    let mut c = mk_state("C", 0.0, ZERO, 1);
    b.transitions = vec![on_complete_row("B")];
    c.transitions = vec![on_complete_row("C")];
    a.transitions = vec![
        row_to(
            c_var("go", Op::Eq, ParamValue::Bool(true)),
            "B",
            Momentum::Cut,
            3,
        ),
        on_complete_row("C"),
    ];
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b, c], "A")], "Behavior");
    add_param(&mut bh, "go", ParamType::Bool, ParamValue::Bool(false));
    let mut h = Harness::new(bh);
    let input = TickInput::default();
    let mut states = vec![];
    for _ in 0..4 {
        h.tick(&input);
        states.push(h.state("M"));
    }
    assert_eq!(states[3], "C", "falls through, got {:?}", states);
    assert!(!states.contains(&"B".to_string()));
}

#[test]
fn cond_input_edges() {
    let mut a = mk_state("A", 0.0, ZERO, 5);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.transitions = vec![row_to(
        c_input(&["t_jump"], InputMode::AnyPressed),
        "B",
        Momentum::Cut,
        3,
    )];
    b.transitions = vec![
        row_to(
            c_input(&["t_jump"], InputMode::AnyPressed),
            "A",
            Momentum::Cut,
            3,
        ),
        on_complete_row("B"),
    ];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let mut states = vec![];
    for tick in 0..9 {
        let input = match tick {
            2..=5 => held(&["t_jump"]),
            7..=8 => held(&["t_jump"]),
            _ => TickInput::default(),
        };
        h.tick(&input);
        states.push(h.state("M"));
    }
    assert_eq!(states[0], "A");
    assert_eq!(states[1], "A");
    assert_eq!(states[2], "B", "press edge -> B, got {:?}", states);
    assert!(
        states[3] == "B" && states[4] == "B" && states[5] == "B",
        "hold holds, got {:?}",
        states
    );
    assert_eq!(states[6], "B", "release alone does nothing");
    assert_eq!(states[7], "A", "second press -> A, got {:?}", states);
}

#[test]
fn cond_input_all_released() {
    let mut run = mk_state("Run", 0.1, Vec3::new(1.0, 0.0, 0.0), 1);
    let mut idle = mk_state("Idle", 0.0, ZERO, 1);
    run.transitions = vec![
        row_to(
            c_input(&["t_right"], InputMode::AllReleased),
            "Idle",
            Momentum::Cut,
            3,
        ),
        on_complete_row("Run"),
    ];
    idle.transitions = vec![on_complete_row("Idle")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![run, idle], "Run")],
        "Behavior",
    ));
    let mut states = vec![];
    for tick in 0..6 {
        let input = if tick < 4 {
            held(&["t_right"])
        } else {
            TickInput::default()
        };
        h.tick(&input);
        states.push(h.state("M"));
    }
    assert_eq!(
        states,
        vec!["Run", "Run", "Run", "Run", "Idle", "Idle"],
        "got {:?}",
        states
    );
}

#[test]
fn cond_variable() {
    let mut a = mk_state("A", 0.0, ZERO, 4);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.transitions = vec![row_to(
        c_var("n", Op::Gt, ParamValue::Float(5.0)),
        "B",
        Momentum::Cut,
        3,
    )];
    b.transitions = vec![on_complete_row("B")];
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Behavior");
    add_param(&mut bh, "n", ParamType::Float, ParamValue::Float(3.0));
    let mut h = Harness::new(bh);
    let input = TickInput::default();
    let mut states = vec![];
    for tick in 0..4 {
        if tick == 2 {
            h.rt.set_param("n", ParamValue::Float(7.0));
        }
        h.tick(&input);
        states.push(h.state("M"));
    }
    assert_eq!(states[0], "A");
    assert_eq!(states[1], "A");
    assert_eq!(states[2], "B", "got {:?}", states);
}

#[test]
fn cond_event_delay() {
    let mut a = mk_state("A", 0.0, ZERO, 6);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.transitions = vec![row_to(c_event("go"), "B", Momentum::Cut, 3)];
    b.transitions = vec![on_complete_row("B")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    let mut states = vec![];
    for tick in 0..5 {
        h.tick(&input);
        states.push(h.state("M"));
        if tick == 2 {
            h.rt.emit_event("go");
        }
    }
    assert_eq!(states[2], "A", "not visible same tick, got {:?}", states);
    assert_eq!(states[3], "B", "visible next tick, got {:?}", states);
}

#[test]
fn cond_on_state() {
    let mut a = mk_state("A", 0.0, ZERO, 2);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    let mut x = mk_state("X", 0.0, ZERO, 6);
    let mut y = mk_state("Y", 0.0, ZERO, 1);
    y.transitions = vec![on_complete_row("Y")];
    a.transitions = vec![on_complete_row("B")];
    b.transitions = vec![on_complete_row("B")];
    let m1 = mk_machine("M1", vec![a, b], "A");
    x.transitions = vec![row_to(c_state("M1", "B"), "Y", Momentum::Cut, 3)];
    let m2m = mk_machine("M2", vec![x, y], "X");
    let mut h = Harness::new(mk_behavior(vec![m1, m2m], "Behavior"));
    let input = TickInput::default();
    let mut m2states = vec![];
    for _ in 0..3 {
        h.tick(&input);
        m2states.push(h.state("M2"));
    }
    assert_eq!(m2states[0], "X");
    assert_eq!(m2states[1], "X");
    assert_eq!(m2states[2], "Y", "got {:?}", m2states);
}

#[test]
fn cond_custom() {
    let mut a = mk_state("A", 0.0, ZERO, 4);
    let mut b = mk_state("B", 0.0, ZERO, 1);
    a.transitions = vec![row_to(c_custom("go3"), "B", Momentum::Cut, 3)];
    b.transitions = vec![on_complete_row("B")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let counter = Rc::new(Cell::new(0u64));
    let c2 = counter.clone();
    h.rt.register_custom_condition("go3", Box::new(move || c2.get() >= 2));
    let input = TickInput::default();
    let mut states = vec![];
    for tick in 0..4 {
        counter.set(tick);
        h.tick(&input);
        states.push(h.state("M"));
    }
    assert_eq!(states[0], "A");
    assert_eq!(states[1], "A");
    assert_eq!(states[2], "B", "got {:?}", states);
}

#[test]
fn momentum_preserve() {
    let mut a = mk_state("A", 0.12, Vec3::new(1.0, 0.0, 0.0), 1);
    let b = mk_state("B", 0.0, ZERO, 4);
    a.transitions = vec![row_to(
        on_complete_row("B").condition,
        "B",
        Momentum::Preserve,
        4,
    )];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    let mut speeds = vec![];
    let mut last_x = 0.0;
    for _ in 0..5 {
        h.tick(&input);
        speeds.push(h.pos.x - last_x);
        last_x = h.pos.x;
    }
    let want = [0.12, 0.09, 0.06, 0.03, 0.0];
    for (i, w) in want.iter().enumerate() {
        assert!(
            approx(speeds[i], *w, 1e-4),
            "blend frame {}: got {} want {}",
            i,
            speeds[i],
            w
        );
    }
    assert!(approx(h.pos.x, 0.3, 1e-4), "total 0.3, got {}", h.pos.x);
}

#[test]
fn momentum_cut() {
    let mut a = mk_state("A", 0.12, Vec3::new(1.0, 0.0, 0.0), 1);
    let b = mk_state("B", 0.0, ZERO, 4);
    a.transitions = vec![on_complete_row("B")];
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![a, b], "A")],
        "Behavior",
    ));
    let input = TickInput::default();
    let mut speeds = vec![];
    let mut last_x = 0.0;
    for _ in 0..5 {
        h.tick(&input);
        speeds.push(h.pos.x - last_x);
        last_x = h.pos.x;
    }
    assert!(approx(speeds[0], 0.12, 1e-4));
    for (i, v) in speeds.iter().enumerate().skip(1) {
        assert!(v.abs() < 1e-4, "cut frame {} is 0, got {}", i, v);
    }
    assert!(approx(h.pos.x, 0.12, 1e-4));
}

fn switch_behaviors() -> (
    frameforge_core::FrameBehavior,
    frameforge_core::FrameBehavior,
) {
    let mut idle_a = mk_state("IdleA", 0.0, ZERO, 1);
    idle_a.transitions = vec![on_complete_row("IdleA")];
    let mut fall_b = mk_state("FallB", 0.05, Vec3::new(0.0, -1.0, 0.0), 1);
    fall_b.transitions = vec![on_complete_row("FallB")];
    let ground = mk_behavior(vec![mk_machine("M", vec![idle_a], "IdleA")], "Ground");
    let air = mk_behavior(vec![mk_machine("M", vec![fall_b], "FallB")], "Air");
    (ground, air)
}

fn add_jump_row(bh: &mut frameforge_core::FrameBehavior, target: &frameforge_core::FrameBehavior) {
    let mut r = frameforge_core::Transition::default();
    r.condition = c_input(&["t_jump"], InputMode::AnyPressed);
    r.target_behavior_name = target.behavior_name.clone();
    bh.behavior_transitions.push(r);
}

#[test]
fn behavior_switch() {
    let (mut ground, air) = switch_behaviors();
    add_jump_row(&mut ground, &air);
    let mut air2 = air.clone();
    add_jump_row(&mut air2, &ground);
    let mut rt = Runtime::new(ground);
    rt.register_behavior(air2);
    let mut h = Harness { rt, pos: ZERO };
    let mut bhs = vec![];
    let mut sts = vec![];
    for tick in 0..8 {
        let input = match tick {
            2 | 5 => held(&["t_jump"]),
            _ => TickInput::default(),
        };
        h.tick(&input);
        bhs.push(h.rt.behavior_name().to_string());
        sts.push(h.state("M"));
    }
    assert_eq!(bhs[1], "Ground");
    assert_eq!(
        (bhs[2].as_str(), sts[2].as_str()),
        ("Air", "FallB"),
        "got {:?}/{:?}",
        bhs,
        sts
    );
    assert_eq!(bhs[4], "Air");
    assert_eq!((bhs[5].as_str(), sts[5].as_str()), ("Ground", "IdleA"));
    assert!(approx(h.pos.y, -0.15, 1e-4), "fell 3 ticks, y={}", h.pos.y);
}

#[test]
fn behavior_switch_params() {
    let (mut ground, air) = switch_behaviors();
    add_jump_row(&mut ground, &air);
    add_param(
        &mut ground,
        "speed",
        ParamType::Float,
        ParamValue::Float(1.0),
    );
    let mut air_reg = air.clone();
    add_param(
        &mut air_reg,
        "speed",
        ParamType::Float,
        ParamValue::Float(1.0),
    );
    let mut h = Harness::new(ground);
    h.rt.register_behavior(air_reg);
    for tick in 0..4 {
        if tick == 1 {
            h.rt.set_param("speed", ParamValue::Float(9.0));
        }
        let input = if tick == 2 {
            held(&["t_jump"])
        } else {
            TickInput::default()
        };
        h.tick(&input);
    }
    assert_eq!(h.rt.behavior_name(), "Air");
    assert_eq!(h.rt.get_param("speed"), Some(&ParamValue::Float(9.0)));
}

#[test]
fn behavior_switch_entry_fallback() {
    let mut run = mk_state("Run", 0.1, Vec3::new(1.0, 0.0, 0.0), 1);
    run.transitions = vec![on_complete_row("Run")];
    let mut drift = mk_state("Drift", 0.0, ZERO, 2);
    drift.direction_source = DirectionSource::Entry;
    drift.displacement_source = DisplacementSource::Entry;
    let mut ground = mk_behavior(vec![mk_machine("M", vec![run], "Run")], "Ground");
    let air = mk_behavior(vec![mk_machine("M", vec![drift], "Drift")], "Air");
    add_jump_row(&mut ground, &air);
    let mut h = Harness::new(ground);
    h.rt.register_behavior(air);
    for tick in 0..5 {
        let input = if tick == 2 {
            held(&["t_jump"])
        } else {
            TickInput::default()
        };
        h.tick(&input);
    }
    assert_eq!(h.rt.behavior_name(), "Air");
    assert_eq!(h.state("M"), "Drift");
    assert!(approx(h.pos.x, 0.5, 1e-4), "entry fallback, x={}", h.pos.x);
}

#[test]
fn collision_floor_land() {
    let mut fall = mk_state("Fall", 0.15, Vec3::new(0.0, -1.0, 0.0), 1);
    fall.transitions = vec![on_complete_row("Fall")];
    let mut land = mk_state("Land", 0.0, ZERO, 2);
    let mut idle = mk_state("Idle", 0.0, ZERO, 1);
    land.transitions = vec![on_complete_row("Idle")];
    idle.transitions = vec![on_complete_row("Idle")];
    let mut m = mk_machine("M", vec![fall, land, idle], "Fall");
    m.default_resp_floor = Some(mk_resp("Land", 0.0, 3));
    let mut h = Harness::new_at(mk_behavior(vec![m], "Behavior"), Vec3::new(0.0, 3.0, 0.0));
    let input = TickInput::default();
    let mut lands = vec![];
    let mut prev = String::new();
    for tick in 0..30 {
        h.tick_physics(&input);
        let s = h.state("M");
        if s == "Land" && prev != "Land" {
            lands.push(tick);
        }
        prev = s;
    }
    assert_eq!(lands.len(), 1, "Land once, got {:?}", lands);
    assert_eq!(lands[0], 16, "landing tick, got {:?}", lands);
    assert_eq!(h.state("M"), "Idle");
    assert!(
        (h.pos.y - 0.5).abs() < 0.05,
        "rests on floor, y={}",
        h.pos.y
    );
}

#[test]
fn collision_wall_bounce() {
    let mut run = mk_state("Run", 0.2, Vec3::new(1.0, 0.0, 0.0), 1);
    run.transitions = vec![on_complete_row("Run")];
    let mut bounce = mk_state("Bounce", 0.0, ZERO, 4);
    bounce.direction_source = DirectionSource::ImpactNormal;
    bounce.displacement_source = DisplacementSource::Incoming;
    bounce.restitution = 0.5;
    let mut done = mk_state("Done", 0.0, ZERO, 1);
    done.transitions = vec![on_complete_row("Done")];
    bounce.transitions = vec![on_complete_row("Done")];
    let mut m = mk_machine("M", vec![run, bounce, done], "Run");
    m.default_resp_wall = Some(mk_resp("Bounce", 0.0, 3));
    let mut h = Harness::new_at(mk_behavior(vec![m], "Behavior"), Vec3::new(0.0, 0.5, 0.0));
    let input = TickInput::default();
    let mut bounces = vec![];
    let mut xs = vec![];
    let mut prev = String::new();
    let mut entry_x = 0.0;
    for tick in 0..34 {
        h.tick_physics(&input);
        xs.push(h.pos.x);
        let s = h.state("M");
        if s == "Bounce" && prev != "Bounce" {
            bounces.push(tick);
        }
        prev = s;
        if tick == 23 {
            entry_x = h.pos.x;
        }
    }
    assert_eq!(bounces, vec![23], "got {:?}", bounces);
    for i in [24, 25, 26, 27] {
        let d = xs[i - 1] - xs[i];
        assert!(
            approx(d, 0.1, 1e-3),
            "bounce frame {} moves -0.1, got {}",
            i,
            d
        );
    }
    assert!(
        approx(entry_x - h.pos.x, 0.4, 1e-3),
        "rebounded 0.4, got {}",
        entry_x - h.pos.x
    );
    assert_eq!(h.state("M"), "Done");
}

#[test]
fn collision_min_speed() {
    let mut run = mk_state("Run", 0.2, Vec3::new(1.0, 0.0, 0.0), 1);
    run.transitions = vec![on_complete_row("Run")];
    let mut bounce = mk_state("Bounce", 0.0, ZERO, 4);
    bounce.direction_source = DirectionSource::ImpactNormal;
    bounce.displacement_source = DisplacementSource::Incoming;
    let mut m = mk_machine("M", vec![run, bounce], "Run");
    m.default_resp_wall = Some(mk_resp("Bounce", 100.0, 3));
    let mut h = Harness::new_at(mk_behavior(vec![m], "Behavior"), Vec3::new(0.0, 0.5, 0.0));
    let input = TickInput::default();
    let mut states = vec![];
    for _ in 0..30 {
        h.tick_physics(&input);
        states.push(h.state("M"));
    }
    assert!(
        !states.contains(&"Bounce".to_string()),
        "suppressed by min speed"
    );
    assert_eq!(states[29], "Run");
    assert!(
        (h.pos.x - 4.7).abs() < 0.05,
        "pressed against wall, x={}",
        h.pos.x
    );
}

#[test]
fn collision_wall_rearm() {
    let mut run = mk_state("Run", 0.2, Vec3::new(1.0, 0.0, 0.0), 1);
    run.transitions = vec![on_complete_row("Run")];
    let mut slide = mk_state("SlideB", 0.15, Vec3::new(0.2, 0.0, 1.0).normalized(), 10);
    slide.transitions = vec![on_complete_row("Run")];
    let mut m = mk_machine("M", vec![run, slide], "Run");
    m.default_resp_wall = Some(mk_resp("SlideB", 0.0, 3));
    let mut h = Harness::new_at(mk_behavior(vec![m], "Behavior"), Vec3::new(0.0, 0.5, 0.0));
    let input = TickInput::default();
    let mut entries = vec![];
    let mut prev = String::new();
    for tick in 0..65 {
        if tick == 36 {
            h.pos = Vec3::new(0.0, 0.5, 0.0);
        }
        h.tick_physics(&input);
        let s = h.state("M");
        if s == "SlideB" && prev != "SlideB" {
            entries.push(tick);
        }
        prev = s;
    }
    assert_eq!(entries, vec![23, 59], "got {:?}", entries);
}

#[test]
fn collision_floor_lost() {
    let mut fall = mk_state("Fall", 0.15, Vec3::new(0.0, -1.0, 0.0), 1);
    fall.transitions = vec![on_complete_row("Fall")];
    let mut land = mk_state("Land", 0.0, ZERO, 2);
    let mut settle = mk_state("Settle", 0.005, Vec3::new(0.0, -1.0, 0.0), 1);
    land.transitions = vec![on_complete_row("Settle")];
    settle.transitions = vec![on_complete_row("Settle")];
    let mut m = mk_machine("M", vec![fall, land, settle], "Fall");
    m.default_resp_floor = Some(mk_resp("Land", 0.0, 3));
    let mut ground = mk_behavior(vec![m], "Ground");
    let mut fall2 = mk_state("Fall2", 0.1, Vec3::new(0.0, -1.0, 0.0), 1);
    fall2.transitions = vec![on_complete_row("Fall2")];
    let air = mk_behavior(vec![mk_machine("M", vec![fall2], "Fall2")], "Air");
    let mut r = frameforge_core::Transition::default();
    r.condition = c_event("floor_lost");
    r.target_behavior_name = "Air".to_string();
    ground.behavior_transitions.push(r);
    let mut h = Harness::new_at(ground, Vec3::new(0.0, 3.0, 0.0));
    h.rt.register_behavior(air);
    let input = TickInput::default();
    for tick in 0..28 {
        if tick == 24 {
            h.pos = Vec3::new(0.0, 5.0, 0.0);
        }
        h.tick_physics(&input);
    }
    assert_eq!(h.rt.behavior_name(), "Air", "floor_lost -> Air");
    assert_eq!(h.state("M"), "Fall2");
}
