//! Phase B engine-extension tests: G-1 input buffering, G-2 OnStick,
//! G-3 state_step, G-4 param assigns/countdowns/spin, G-5 steering.

#![allow(clippy::field_reassign_with_default)]

mod common;

use common::*;
use frameforge_core::input::TickInput;
use frameforge_core::tick::ContactState;
use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{
    Condition, ConditionType, EnterVy, FaceMode, FrameState, InputMode, Momentum, Op, ParamAssign,
    ParamType, ParamValue, SpinDetectConfig, SteerConfig, StickAngleVs, TurnModel, TurnTier,
    STATE_STEP_PARAM,
};
use std::collections::{HashMap, HashSet};

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

/// Tick with an explicit stick vector (G-2/G-5).
fn stick_tick(h: &mut Harness, sx: f32, sy: f32, input: &TickInput) -> Vec3 {
    h.rt.set_stick(sx, sy);
    let d = h.rt.tick_delta(input);
    h.pos = h.pos + d;
    h.rt.tick_contact(&ContactState::default());
    d
}

fn c_input_buf(actions: &[&str], buffer: u32) -> Condition {
    Condition {
        cond_type: ConditionType::OnInput,
        input_actions: actions.iter().map(|s| s.to_string()).collect(),
        input_mode: InputMode::AnyPressed,
        buffer_ticks: buffer,
        ..Default::default()
    }
}

fn c_stick(
    rmin: f32,
    rmax: f32,
    vs: StickAngleVs,
    amin: f32,
    amax: f32,
) -> Condition {
    Condition {
        cond_type: ConditionType::OnStick,
        stick_radius_min: rmin,
        stick_radius_max: rmax,
        stick_angle_vs: vs,
        stick_angle_min_deg: amin,
        stick_angle_max_deg: amax,
        ..Default::default()
    }
}

fn self_loop(state: &mut FrameState) {
    state.transitions = vec![row_to(
        c_var("never_set_param_xyz", Op::Eq, ParamValue::Int(1)),
        &state.state_name.clone(),
        Momentum::Cut,
        0,
    )];
}

// ---------------------------------------------------------------------------
// G-1: input buffering
// ---------------------------------------------------------------------------

/// Buffered press fires after the just_pressed edge is long gone.
#[test]
fn buffered_press_fires_late() {
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    // Row 1 blocks ticks 1..3 via a param; row 2 is the buffered jump.
    a.transitions = vec![
        row_to(
            c_var("block", Op::Eq, ParamValue::Int(1)),
            "A",
            Momentum::Cut,
            0,
        ),
        row_to(c_input_buf(&["jump"], 4), "B", Momentum::Cut, 0),
    ];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    self_loop(&mut b);
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Buf");
    add_param(&mut bh, "block", ParamType::Int, ParamValue::Int(1));
    let mut h = Harness::new(bh);

    // Tick 1: press jump (blocked by row 1).
    h.tick(&press(&["jump"]));
    assert_eq!(h.state("M"), "A");
    // Ticks 2-3: released, still blocked.
    h.tick(&release());
    h.tick(&release());
    assert_eq!(h.state("M"), "A");
    // Tick 4: unblock; the 3-tick-old press is still within buffer 4.
    h.rt.set_param("block", ParamValue::Int(0));
    h.tick(&release());
    assert_eq!(h.state("M"), "B", "buffered press should fire on tick 4");
}

/// A buffered press is consumed by the row that uses it: one press cannot
/// drive two transitions.
#[test]
fn buffered_press_consumed_once() {
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    a.transitions = vec![row_to(c_input_buf(&["jump"], 4), "B", Momentum::Cut, 0)];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    b.transitions = vec![row_to(c_input_buf(&["jump"], 4), "C", Momentum::Cut, 0)];
    let mut c = mk_state("C", 0.0, ZERO, 1000);
    self_loop(&mut c);
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a, b, c], "A")], "Buf"));

    h.tick(&press(&["jump"])); // -> B, press consumed
    assert_eq!(h.state("M"), "B");
    for _ in 0..6 {
        h.tick(&release());
        assert_eq!(h.state("M"), "B", "consumed press must not reach C");
    }
}

/// buffer_ticks = 0 keeps the legacy just_pressed-only behavior.
#[test]
fn unbuffered_press_does_not_fire_late() {
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    a.transitions = vec![
        row_to(
            c_var("block", Op::Eq, ParamValue::Int(1)),
            "A",
            Momentum::Cut,
            0,
        ),
        row_to(c_input(&["jump"], InputMode::AnyPressed), "B", Momentum::Cut, 0),
    ];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    self_loop(&mut b);
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "NoBuf");
    add_param(&mut bh, "block", ParamType::Int, ParamValue::Int(1));
    let mut h = Harness::new(bh);

    h.tick(&press(&["jump"]));
    h.tick(&release());
    h.tick(&release());
    h.rt.set_param("block", ParamValue::Int(0));
    h.tick(&release());
    assert_eq!(
        h.state("M"),
        "A",
        "without buffering the old press must not fire"
    );
}

// ---------------------------------------------------------------------------
// G-2: OnStick
// ---------------------------------------------------------------------------

#[test]
fn onstick_radius() {
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    a.transitions = vec![
        row_to(c_stick(0.5, 99.0, StickAngleVs::Facing, 0.0, 180.0), "B", Momentum::Cut, 0),
        row_to(
            c_var("never_set_param_xyz", Op::Eq, ParamValue::Int(1)),
            "A",
            Momentum::Cut,
            0,
        ),
    ];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    self_loop(&mut b);
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Stick"));

    stick_tick(&mut h, 0.2, 0.0, &release());
    assert_eq!(h.state("M"), "A", "radius 0.2 < min 0.5");
    stick_tick(&mut h, 0.8, 0.0, &release());
    assert_eq!(h.state("M"), "B", "radius 0.8 within range");
}

#[test]
fn onstick_angle_vs_facing() {
    // Facing +Z (yaw 0). Stick forward (0,1) -> world +Z -> angle 0.
    // Stick back (0,-1) -> world -Z -> angle 180.
    let mk = || {
        let mut a = mk_state("A", 0.0, ZERO, 1000);
        a.transitions = vec![
            row_to(
                c_stick(0.0, 99.0, StickAngleVs::Facing, 0.0, 45.0),
                "B",
                Momentum::Cut,
                0,
            ),
            row_to(
                c_var("never_set_param_xyz", Op::Eq, ParamValue::Int(1)),
                "A",
                Momentum::Cut,
                0,
            ),
        ];
        let mut b = mk_state("B", 0.0, ZERO, 1000);
        self_loop(&mut b);
        let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Stick"));
        h.rt.set_facing_yaw(0.0);
        h
    };
    let mut h = mk();
    stick_tick(&mut h, 0.0, 1.0, &release());
    assert_eq!(h.state("M"), "B", "stick aligned with facing fires");

    let mut h = mk();
    stick_tick(&mut h, 0.0, -1.0, &release());
    assert_eq!(h.state("M"), "A", "stick opposite facing does not fire");
}

#[test]
fn onstick_angle_vs_velocity() {
    // Steered state accelerates along facing (+Z). Build velocity with the
    // row blocked, then: stick sideways (+X) -> 90 deg vs velocity -> no
    // fire; stick forward -> 0 deg -> fires.
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    let mut st = SteerConfig::default();
    st.accel_forward = 1.0;
    a.steer = Some(st);
    a.transitions = vec![
        row_to(
            c_var("block", Op::Eq, ParamValue::Int(1)),
            "A",
            Momentum::Cut,
            0,
        ),
        row_to(
            c_stick(0.0, 99.0, StickAngleVs::Velocity, 0.0, 45.0),
            "B",
            Momentum::Cut,
            0,
        ),
    ];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    self_loop(&mut b);
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Stick");
    add_param(&mut bh, "block", ParamType::Int, ParamValue::Int(1));
    let mut h = Harness::new(bh);
    h.rt.set_facing_yaw(0.0);

    // Ticks 1-3: stick forward, blocked; velocity builds to 3 along +Z.
    for _ in 0..3 {
        stick_tick(&mut h, 0.0, 1.0, &release());
    }
    assert_eq!(h.state("M"), "A");
    assert!(approx(h.rt.track_velocity("M").z, 3.0, 1e-4));

    // Tick 4: unblock, stick sideways -> 90 deg vs velocity -> stays A.
    h.rt.set_param("block", ParamValue::Int(0));
    stick_tick(&mut h, 1.0, 0.0, &release());
    assert_eq!(h.state("M"), "A", "90 deg vs velocity must not fire");

    // Tick 5: stick forward -> 0 deg -> fires.
    stick_tick(&mut h, 0.0, 1.0, &release());
    assert_eq!(h.state("M"), "B", "0 deg vs velocity fires");
}

// ---------------------------------------------------------------------------
// G-3: state_step
// ---------------------------------------------------------------------------

#[test]
fn state_step_variable() {
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    a.transitions = vec![
        row_to(
            c_var(STATE_STEP_PARAM, Op::Ge, ParamValue::Int(5)),
            "B",
            Momentum::Cut,
            0,
        ),
        row_to(
            c_var("never_set_param_xyz", Op::Eq, ParamValue::Int(1)),
            "A",
            Momentum::Cut,
            0,
        ),
    ];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    self_loop(&mut b);
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Step"));
    // Frame during tick N (1-indexed) is N-1: fires at tick 6 (frame 5).
    for _ in 0..5 {
        h.tick(&release());
        assert_eq!(h.state("M"), "A");
    }
    h.tick(&release());
    assert_eq!(h.state("M"), "B", "state_step >= 5 fires at frame 5");
}

// ---------------------------------------------------------------------------
// G-4: param assigns, countdowns, spin
// ---------------------------------------------------------------------------

#[test]
fn on_fire_set_and_enter_params() {
    let mut a = mk_state("A", 0.0, ZERO, 1);
    let mut row = row_to(
        Condition {
            cond_type: ConditionType::OnComplete,
            ..Default::default()
        },
        "B",
        Momentum::Cut,
        0,
    );
    row.on_fire_params = vec![ParamAssign::Set {
        name: "flag.from_row".to_string(),
        value: ParamValue::Int(7),
    }];
    a.transitions = vec![row];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    b.enter_params = vec![ParamAssign::Set {
        name: "flag.from_enter".to_string(),
        value: ParamValue::Bool(true),
    }];
    self_loop(&mut b);
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Flags"));

    // Duration 1: OnComplete fires at tick 2 (frame 1 >= 1).
    h.tick(&release());
    assert_eq!(h.state("M"), "A");
    h.tick(&release());
    assert_eq!(h.state("M"), "B");
    assert_eq!(
        h.rt.get_param("flag.from_row"),
        Some(&ParamValue::Int(7)),
        "on-fire Set applied"
    );
    assert_eq!(
        h.rt.get_param("flag.from_enter"),
        Some(&ParamValue::Bool(true)),
        "enter Set applied"
    );
}

#[test]
fn countdown_ticks_down() {
    let mut a = mk_state("A", 0.0, ZERO, 1);
    let mut row = row_to(
        Condition {
            cond_type: ConditionType::OnComplete,
            ..Default::default()
        },
        "B",
        Momentum::Cut,
        0,
    );
    row.on_fire_params = vec![ParamAssign::Countdown {
        name: "input_lock".to_string(),
        ticks: 3,
    }];
    a.transitions = vec![row];
    let mut b = mk_state("B", 0.0, ZERO, 1000);
    self_loop(&mut b);
    let mut h = Harness::new(mk_behavior(vec![mk_machine("M", vec![a, b], "Lock")], "Lock"));

    h.tick(&release());
    h.tick(&release()); // fires here; armed to 3 during tick 2
    assert_eq!(h.state("M"), "B");
    assert_eq!(h.rt.get_param("input_lock"), Some(&ParamValue::Int(3)));
    h.tick(&release());
    assert_eq!(h.rt.get_param("input_lock"), Some(&ParamValue::Int(2)));
    h.tick(&release());
    assert_eq!(h.rt.get_param("input_lock"), Some(&ParamValue::Int(1)));
    h.tick(&release());
    assert_eq!(h.rt.get_param("input_lock"), Some(&ParamValue::Int(0)));
    h.tick(&release());
    assert_eq!(
        h.rt.get_param("input_lock"),
        Some(&ParamValue::Int(0)),
        "countdown clamps at 0"
    );
}

#[test]
fn spin_valid_published_as_param() {
    let mut a = mk_state("A", 0.0, ZERO, 1000);
    self_loop(&mut a);
    let mut bh = mk_behavior(vec![mk_machine("M", vec![a], "A")], "Spin");
    bh.spin_detect = Some(SpinDetectConfig::default());
    let mut h = Harness::new(bh);

    // Two full turns at 10 deg/tick.
    for i in 0..70 {
        let ang = (i as f32) * 10.0 * std::f32::consts::PI / 180.0;
        stick_tick(&mut h, ang.cos(), ang.sin(), &release());
    }
    assert_eq!(
        h.rt.get_param("spin.valid"),
        Some(&ParamValue::Bool(true)),
        "spin gesture publishes spin.valid"
    );
    // Buffer holds for 30 neutral ticks.
    for _ in 0..30 {
        stick_tick(&mut h, 0.0, 0.0, &release());
    }
    assert_eq!(
        h.rt.get_param("spin.valid"),
        Some(&ParamValue::Bool(true)),
        "30-tick buffer"
    );
    stick_tick(&mut h, 0.0, 0.0, &release());
    assert_eq!(
        h.rt.get_param("spin.valid"),
        Some(&ParamValue::Bool(false)),
        "buffer expired"
    );
}

// ---------------------------------------------------------------------------
// G-5: steering
// ---------------------------------------------------------------------------

fn run_state(name: &str, steer: SteerConfig, dur: u32) -> FrameState {
    let mut s = mk_state(name, 0.0, ZERO, dur);
    s.steer = Some(steer);
    self_loop(&mut s);
    s
}

#[test]
fn steer_accel_stops_at_cap() {
    let mut st = SteerConfig::default();
    st.accel_forward = 2.0;
    st.speed_cap = 10.0;
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![run_state("Run", st, 1000)], "Run")],
        "Steer",
    ));
    h.rt.set_facing_yaw(0.0);
    for _ in 0..5 {
        stick_tick(&mut h, 0.0, 1.0, &release());
    }
    let v = h.rt.track_velocity("M");
    assert!(
        approx(v.z, 10.0, 1e-4),
        "accel stops at cap: velocity {:?}",
        v
    );
    // Two more ticks: no growth above the cap.
    stick_tick(&mut h, 0.0, 1.0, &release());
    stick_tick(&mut h, 0.0, 1.0, &release());
    let v = h.rt.track_velocity("M");
    assert!(approx(v.z, 10.0, 1e-4), "stays at cap: {:?}", v);
}

#[test]
fn steer_decel_above_cap() {
    // Fast (authored, 30 u/tick) -> Run (steered, cap 10, decel 2).
    let mut fast = mk_state("Fast", 30.0, Vec3::new(0.0, 0.0, 1.0), 1);
    fast.transitions = vec![row_to(
        Condition {
            cond_type: ConditionType::OnComplete,
            ..Default::default()
        },
        "Run",
        Momentum::Cut,
        0,
    )];
    let mut st = SteerConfig::default();
    st.speed_cap = 10.0;
    st.decel_above_cap = 2.0;
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![fast, run_state("Run", st, 1000)], "Fast")],
        "Steer",
    ));
    h.rt.set_facing_yaw(0.0);
    // Tick 1 in Fast (delta 30); tick 2 enters Run.
    stick_tick(&mut h, 0.0, 0.0, &release());
    assert_eq!(h.state("M"), "Fast");
    let d = stick_tick(&mut h, 0.0, 0.0, &release());
    assert_eq!(h.state("M"), "Run");
    // Seeded at 30, one decel step toward the cap of 10.
    assert!(
        approx(d.z, 28.0, 1e-4),
        "decel above cap: delta {:?}",
        d
    );
    assert!(approx(h.rt.track_velocity("M").z, 28.0, 1e-4));
}

#[test]
fn steer_gravity_and_terminal() {
    let mut st = SteerConfig::default();
    st.gravity = 2.0;
    st.terminal_velocity = 5.0;
    st.enter_vy = EnterVy::Set(0.0);
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![run_state("Fall", st, 1000)], "Fall")],
        "Steer",
    ));
    let mut dys = Vec::new();
    for _ in 0..6 {
        dys.push(stick_tick(&mut h, 0.0, 0.0, &release()).y);
    }
    assert!(approx(dys[0], -2.0, 1e-4), "{:?}", dys);
    assert!(approx(dys[1], -4.0, 1e-4), "{:?}", dys);
    for (i, dy) in dys.iter().enumerate().skip(2) {
        assert!(approx(*dy, -5.0, 1e-4), "tick {}: {:?}", i, dys);
    }
}

#[test]
fn steer_turn_tiers_and_quickturn() {
    // Tiered turn: 10 deg/tick cap, snap (no accel fractions).
    let mut st = SteerConfig::default();
    st.face_mode = FaceMode::Stick;
    st.turn = TurnModel {
        deadzone_deg: 0.5,
        tiers: vec![TurnTier {
            speed_max: 1000.0,
            cap_base: 10.0,
            cap_per_speed: 0.0,
            cap_per_radius: 0.0,
            cap_min: 0.0,
            cap_max: 0.0,
        }],
        accel_near_frac: 0.0,
        accel_far_frac: 0.0,
        far_angle_deg: 45.0,
        max_angle_deg: 0.0,
    };
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![run_state("Run", st, 1000)], "Run")],
        "Steer",
    ));
    h.rt.set_facing_yaw(0.0);
    // Stick +X -> world +X -> target yaw 90.
    stick_tick(&mut h, 1.0, 0.0, &release());
    assert!(
        approx(h.rt.track_facing_yaw("M"), 10.0, 1e-4),
        "one capped turn step: {}",
        h.rt.track_facing_yaw("M")
    );

    // Quickturn: stick 180 deg off -> flat 25 deg/tick.
    let mut st2 = SteerConfig::default();
    st2.face_mode = FaceMode::Stick;
    st2.quickturn_angle_deg = 135.0;
    st2.quickturn_rate_deg = 25.0;
    let mut h2 = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![run_state("Run", st2, 1000)], "Run")],
        "Steer2",
    ));
    h2.rt.set_facing_yaw(0.0);
    stick_tick(&mut h2, 0.0, -1.0, &release()); // world -Z -> yaw 180
    assert!(
        approx(h2.rt.track_facing_yaw("M"), 25.0, 1e-3),
        "quickturn step: {}",
        h2.rt.track_facing_yaw("M")
    );
}

#[test]
fn steer_face_velocity() {
    // Glide keeps authored horizontal motion and snaps facing to it.
    let mut push = mk_state("Push", 4.0, Vec3::new(0.0, 0.0, 1.0), 2);
    push.transitions = vec![row_to(
        Condition {
            cond_type: ConditionType::OnComplete,
            ..Default::default()
        },
        "Glide",
        Momentum::Cut,
        0,
    )];
    let mut st = SteerConfig::default();
    st.face_mode = FaceMode::Velocity;
    let mut h = Harness::new(mk_behavior(
        vec![mk_machine("M", vec![push, run_state("Glide", st, 1000)], "Push")],
        "Steer",
    ));
    h.rt.set_facing_yaw(45.0);
    for _ in 0..4 {
        stick_tick(&mut h, 0.0, 0.0, &release());
    }
    assert_eq!(h.state("M"), "Glide");
    // Velocity is +Z (from Push's entry motion); facing snaps to yaw 0.
    assert!(
        approx(h.rt.track_facing_yaw("M"), 0.0, 1e-3),
        "facing {:?}",
        h.rt.track_facing_yaw("M")
    );
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Validator coverage for the new fields
// ---------------------------------------------------------------------------
#[test]
fn validate_new_fields() {
    use frameforge_core::validate::validate_behavior;

    // buffer_ticks on a non-AnyPressed row warns.
    let mut s = mk_state("A", 0.0, ZERO, 10);
    let mut c = c_input(&["jump"], InputMode::AnyHeld);
    c.buffer_ticks = 3;
    s.transitions = vec![row_to(c, "A", Momentum::Cut, 0)];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![s], "A")], "V"));
    assert!(
        issues.iter().any(|i| i.message.contains("buffer_ticks")),
        "{:?}",
        issues.iter().map(|i| &i.message).collect::<Vec<_>>()
    );

    // state_step does not warn as an unknown parameter.
    let mut s = mk_state("A", 0.0, ZERO, 10);
    s.transitions = vec![row_to(
        c_var(STATE_STEP_PARAM, Op::Ge, ParamValue::Int(1)),
        "A",
        Momentum::Cut,
        0,
    )];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![s], "A")], "V"));
    assert!(
        !issues
            .iter()
            .any(|i| i.message.contains("unknown parameter")),
        "{:?}",
        issues.iter().map(|i| &i.message).collect::<Vec<_>>()
    );

    // Inconsistent OnStick range warns.
    let mut s = mk_state("A", 0.0, ZERO, 10);
    s.transitions = vec![row_to(
        c_stick(0.8, 0.2, StickAngleVs::Facing, 0.0, 90.0),
        "A",
        Momentum::Cut,
        0,
    )];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![s], "A")], "V"));
    assert!(
        issues.iter().any(|i| i.message.contains("On Stick")),
        "{:?}",
        issues.iter().map(|i| &i.message).collect::<Vec<_>>()
    );

    // Zero-tick countdown warns.
    let mut s = mk_state("A", 0.0, ZERO, 10);
    s.enter_params = vec![ParamAssign::Countdown {
        name: "x".to_string(),
        ticks: 0,
    }];
    s.transitions = vec![row_to(
        c_var("never_set_param_xyz", Op::Eq, ParamValue::Int(1)),
        "A",
        Momentum::Cut,
        0,
    )];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![s], "A")], "V"));
    assert!(
        issues.iter().any(|i| i.message.contains("0 ticks")),
        "{:?}",
        issues.iter().map(|i| &i.message).collect::<Vec<_>>()
    );
}

#[test]
fn new_fields_json_round_trip() {
    // A behavior exercising every new Phase-B field survives JSON
    // serialization unchanged (what the editor will write).
    let mut st = SteerConfig::default();
    st.accel_forward = 0.5;
    st.speed_cap = 3.0;
    st.speed_cap_per_radius = 11.0;
    st.face_mode = FaceMode::Stick;
    st.turn = TurnModel {
        deadzone_deg: 0.5,
        tiers: vec![TurnTier {
            speed_max: 14.0,
            cap_base: 6.5,
            cap_per_speed: 0.0,
            cap_per_radius: 0.0,
            cap_min: 0.0,
            cap_max: 0.0,
        }],
        accel_near_frac: 0.05,
        accel_far_frac: 0.2,
        far_angle_deg: 45.0,
        max_angle_deg: 95.0,
    };
    st.enter_vy = EnterVy::Set(9.0);
    let mut s = mk_state("Run", 0.0, ZERO, 100);
    s.steer = Some(st);
    s.enter_params = vec![ParamAssign::Countdown {
        name: "lock".to_string(),
        ticks: 25,
    }];
    let mut row = row_to(c_input_buf(&["jump"], 4), "Run", Momentum::Cut, 0);
    row.on_fire_params = vec![ParamAssign::Set {
        name: "flag.x".to_string(),
        value: ParamValue::Bool(true),
    }];
    s.transitions = vec![
        row,
        row_to(
            c_stick(0.1, 2.0, StickAngleVs::Velocity, 95.0, 180.0),
            "Run",
            Momentum::Cut,
            0,
        ),
        row_to(
            c_var(STATE_STEP_PARAM, Op::Ge, ParamValue::Int(10)),
            "Run",
            Momentum::Cut,
            0,
        ),
    ];
    let mut bh = mk_behavior(vec![mk_machine("M", vec![s], "Run")], "RT");
    bh.spin_detect = Some(SpinDetectConfig::default());

    let json = serde_json::to_string_pretty(&bh).expect("serialize");
    let back: frameforge_core::FrameBehavior =
        serde_json::from_str(&json).expect("deserialize");
    assert_eq!(bh, back, "JSON round-trip must be lossless");

    // Spot-check the wire format of the tagged ParamAssign enum.
    assert!(json.contains(r#""op": "countdown""#), "{}", json);
    assert!(json.contains(r#""op": "set""#), "{}", json);
    assert!(json.contains(r#""type": "on_stick""#), "{}", json);
    assert!(json.contains(r#""enter_vy": {"#), "{}", json);
    assert!(json.contains(r#""set": 9.0"#), "{}", json);
}
