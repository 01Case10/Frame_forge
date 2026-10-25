//! Port of `tests/phase5_runner.gd` — 23 validator checks.

#![allow(clippy::field_reassign_with_default)]

mod common;

use common::*;
use frameforge_core::validate::{validate_behavior, Severity};
use frameforge_core::vec3::{Vec3, ZERO};
use frameforge_core::{
    Condition, ConditionType, DirectionSource, DisplacementSource, EventTrigger, FrameState,
    Momentum, Parameter, ResponseRef, StateEvent, Transition,
};

fn mk(sname: &str) -> FrameState {
    mk_state(sname, 1.0, Vec3::new(1.0, 0.0, 0.0), 10)
}

fn row(target: &str) -> Transition {
    on_complete_row(target)
}

fn has(issues: &[frameforge_core::validate::Issue], sev: Severity, substr: &str) -> bool {
    issues
        .iter()
        .any(|i| i.severity == sev && i.message.contains(substr))
}

#[test]
fn clean_behavior_no_issues() {
    let mut a = mk("A");
    let mut b = mk("B");
    a.transitions = vec![row("B")];
    b.transitions = vec![row("A")];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![a, b], "A")], "Test"));
    assert!(issues.is_empty(), "got {:?}", issues);
}

#[test]
fn zero_duration_error() {
    let mut z = mk_state("Z", 1.0, Vec3::new(1.0, 0.0, 0.0), 0);
    z.transitions = vec![row("Z")];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![z], "Z")], "Test"));
    assert!(
        has(&issues, Severity::Error, "zero/negative duration"),
        "got {:?}",
        issues
    );
}

#[test]
fn unnormalized_warning() {
    let mut u = mk("U");
    u.direction = [2.0, 0.0, 0.0];
    u.transitions = vec![row("U")];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![u], "U")], "Test"));
    assert!(
        has(&issues, Severity::Warning, "not normalized"),
        "got {:?}",
        issues
    );
}

#[test]
fn event_frame_range_error() {
    let mut e = mk_state("E", 1.0, Vec3::new(1.0, 0.0, 0.0), 5);
    e.transitions = vec![row("E")];
    e.events = vec![
        mk_event("go", EventTrigger::OnFrame, 9),
        mk_event("go", EventTrigger::OnEnter, 0),
    ];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![e], "E")], "Test"));
    assert!(
        has(&issues, Severity::Error, "out of range"),
        "got {:?}",
        issues
    );
}

#[test]
fn duplicate_event_warning() {
    let mut e = mk_state("E", 1.0, Vec3::new(1.0, 0.0, 0.0), 5);
    e.transitions = vec![row("E")];
    e.events = vec![
        mk_event("go", EventTrigger::OnFrame, 1),
        mk_event("go", EventTrigger::OnEnter, 0),
    ];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![e], "E")], "Test"));
    assert!(
        has(&issues, Severity::Warning, "more than once"),
        "got {:?}",
        issues
    );
}

#[test]
fn zero_rows_error() {
    let t = mk("T");
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![t], "T")], "Test"));
    assert!(
        has(&issues, Severity::Error, "no transition rows"),
        "got {:?}",
        issues
    );
}

#[test]
fn unwired_row_error() {
    let mut w = mk("W");
    w.transitions = vec![Transition::default()];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![w], "W")], "Test"));
    assert!(has(&issues, Severity::Error, "unwired"), "got {:?}", issues);
}

#[test]
fn event_tap_row_ok() {
    let mut v = mk("V");
    let mut r = Transition::default();
    r.fire_event = "ping".to_string();
    v.transitions = vec![r];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![v], "V")], "Test"));
    assert!(
        !has(&issues, Severity::Error, "unwired"),
        "got {:?}",
        issues
    );
}

#[test]
fn unreachable_warning() {
    let mut r1 = mk("R1");
    r1.transitions = vec![row("R1")];
    let mut r2 = mk("R2");
    r2.transitions = vec![row("R2")];
    let issues = validate_behavior(&mk_behavior(
        vec![mk_machine("M", vec![r1, r2], "R1")],
        "Test",
    ));
    assert!(
        has(&issues, Severity::Warning, "unreachable"),
        "got {:?}",
        issues
    );
}

#[test]
fn trap_warning() {
    let mut trap = mk("Trap");
    trap.transitions = vec![row("Trap")];
    let issues = validate_behavior(&mk_behavior(
        vec![mk_machine("M", vec![trap], "Trap")],
        "Test",
    ));
    assert!(has(&issues, Severity::Warning, "trap"), "got {:?}", issues);
}

#[test]
fn collision_exit_not_trap() {
    let mut land = mk_state("Land", 0.0, ZERO, 5);
    land.transitions = vec![row("Land")];
    let mut fall = mk_state("Fall", 2.0, Vec3::new(0.0, -1.0, 0.0), 30);
    fall.transitions = vec![row("Fall")];
    fall.resp_floor = Some(mk_resp("Land", 0.0, 3));
    let m = mk_machine("M", vec![fall, land], "Fall");
    let issues = validate_behavior(&mk_behavior(vec![m], "Test"));
    let fall_traps: Vec<_> = issues
        .iter()
        .filter(|i| {
            i.severity == Severity::Warning && i.message.contains("\"Fall\" looks like a trap")
        })
        .collect();
    assert!(fall_traps.is_empty(), "got {:?}", issues);
}

#[test]
fn impact_untargeted_warning() {
    let mut imp = mk_state("Imp", 1.0, ZERO, 10);
    imp.direction_source = DirectionSource::ImpactNormal;
    imp.transitions = vec![row("Imp")];
    let mut idle = mk_state("Idle", 0.0, ZERO, 10);
    idle.transitions = vec![row("Idle")];
    let m = mk_machine("M", vec![imp, idle], "Imp");
    let issues = validate_behavior(&mk_behavior(vec![m], "Test"));
    assert!(
        has(
            &issues,
            Severity::Warning,
            "no collision response targets it"
        ),
        "got {:?}",
        issues
    );
}

#[test]
fn impact_targeted_ok() {
    let mut imp = mk_state("Imp", 1.0, ZERO, 10);
    imp.direction_source = DirectionSource::ImpactNormal;
    imp.transitions = vec![row("Imp")];
    let mut idle = mk_state("Idle", 0.0, ZERO, 10);
    idle.transitions = vec![row("Idle")];
    idle.resp_wall = Some(mk_resp("Imp", 0.0, 3));
    let m = mk_machine("M", vec![imp, idle], "Imp");
    let issues = validate_behavior(&mk_behavior(vec![m], "Test"));
    assert!(
        !has(
            &issues,
            Severity::Warning,
            "no collision response targets it"
        ),
        "got {:?}",
        issues
    );
}

#[test]
fn preserve_entry_warning() {
    let mut src = mk("Src");
    let mut dst = mk_state("Dst", 0.0, ZERO, 6);
    dst.displacement_source = DisplacementSource::Entry;
    dst.transitions = vec![row("Dst")];
    let prow = row_to(
        on_complete_row("Dst").condition,
        "Dst",
        Momentum::Preserve,
        3,
    );
    src.transitions = vec![prow];
    let issues = validate_behavior(&mk_behavior(
        vec![mk_machine("M", vec![src, dst], "Src")],
        "Test",
    ));
    assert!(
        has(
            &issues,
            Severity::Warning,
            "redundant with the target's ENTRY"
        ),
        "got {:?}",
        issues
    );
}

#[test]
fn unknown_param_warning() {
    let mut bh = mk_behavior(vec![mk_machine("M", vec![mk("A")], "A")], "Test");
    add_param(
        &mut bh,
        "speed",
        frameforge_core::ParamType::Float,
        frameforge_core::ParamValue::Float(0.0),
    );
    let mut vs = mk("VS");
    let mut r = Transition::default();
    r.condition = Condition {
        cond_type: ConditionType::OnVariable,
        param_name: "nope".to_string(),
        ..Default::default()
    };
    r.target_state_name = "VS".to_string();
    vs.transitions = vec![r];
    bh.sub_machines = vec![mk_machine("M", vec![vs], "VS")];
    let issues = validate_behavior(&bh);
    assert!(
        has(&issues, Severity::Warning, "unknown parameter"),
        "got {:?}",
        issues
    );
}

#[test]
fn known_param_ok() {
    let mut bh = mk_behavior(vec![mk_machine("M", vec![mk("A")], "A")], "Test");
    add_param(
        &mut bh,
        "speed",
        frameforge_core::ParamType::Float,
        frameforge_core::ParamValue::Float(0.0),
    );
    let mut vs = mk("VS");
    let mut r = Transition::default();
    r.condition = Condition {
        cond_type: ConditionType::OnVariable,
        param_name: "speed".to_string(),
        ..Default::default()
    };
    r.target_state_name = "VS".to_string();
    vs.transitions = vec![r];
    bh.sub_machines = vec![mk_machine("M", vec![vs], "VS")];
    let issues = validate_behavior(&bh);
    assert!(
        !has(&issues, Severity::Warning, "unknown parameter"),
        "got {:?}",
        issues
    );
}

#[test]
fn input_no_actions_warning() {
    let mut ins = mk("IN");
    let mut r = Transition::default();
    r.condition = Condition {
        cond_type: ConditionType::OnInput,
        ..Default::default()
    };
    r.target_state_name = "IN".to_string();
    ins.transitions = vec![r];
    let issues = validate_behavior(&mk_behavior(vec![mk_machine("M", vec![ins], "IN")], "Test"));
    assert!(
        has(&issues, Severity::Warning, "no actions assigned"),
        "got {:?}",
        issues
    );
}

#[test]
fn empty_machine_warning() {
    let m = common::mk_machine_empty("Empty");
    let issues = validate_behavior(&mk_behavior(vec![m], "Test"));
    assert!(
        has(&issues, Severity::Warning, "has no states"),
        "got {:?}",
        issues
    );
}

#[test]
fn no_entry_error() {
    let mut m = mk_machine("NE", vec![mk("A")], "");
    m.entry_state_name = String::new();
    let issues = validate_behavior(&mk_behavior(vec![m], "Test"));
    assert!(
        has(&issues, Severity::Error, "no entry state"),
        "got {:?}",
        issues
    );
}

#[test]
fn parallel_axes_warning() {
    let mut xa = mk_state("XA", 1.0, Vec3::new(1.0, 0.0, 0.0), 10);
    xa.transitions = vec![row("XA")];
    let mut xb = mk_state("XB", 1.0, Vec3::new(1.0, 0.0, 0.0), 10);
    xb.transitions = vec![row("XB")];
    let issues = validate_behavior(&mk_behavior(
        vec![
            mk_machine("MA", vec![xa], "XA"),
            mk_machine("MB", vec![xb], "XB"),
        ],
        "Test",
    ));
    assert!(
        has(
            &issues,
            Severity::Warning,
            "both author displacement on the X axis"
        ),
        "got {:?}",
        issues
    );
}

#[test]
fn different_axes_ok() {
    let mut xa = mk_state("XA", 1.0, Vec3::new(1.0, 0.0, 0.0), 10);
    xa.transitions = vec![row("XA")];
    let mut yb = mk_state("YB", 1.0, Vec3::new(0.0, 1.0, 0.0), 10);
    yb.transitions = vec![row("YB")];
    let issues = validate_behavior(&mk_behavior(
        vec![
            mk_machine("MA", vec![xa], "XA"),
            mk_machine("MB", vec![yb], "YB"),
        ],
        "Test",
    ));
    assert!(
        !has(&issues, Severity::Warning, "both author displacement"),
        "got {:?}",
        issues
    );
}

#[test]
fn behavior_transition_error() {
    let mut bh = mk_behavior(vec![mk_machine("M", vec![mk("A")], "A")], "Test");
    bh.behavior_transitions = vec![Transition::default()];
    let issues = validate_behavior(&bh);
    assert!(
        has(&issues, Severity::Error, "no target behavior"),
        "got {:?}",
        issues
    );
}

#[test]
fn duplicate_param_warning() {
    let mut bh = mk_behavior(vec![mk_machine("M", vec![mk("A")], "A")], "Test");
    bh.parameters = vec![
        Parameter {
            name: "x".to_string(),
            ..Default::default()
        },
        Parameter {
            name: "x".to_string(),
            ..Default::default()
        },
    ];
    let issues = validate_behavior(&bh);
    assert!(
        has(&issues, Severity::Warning, "Duplicate parameter"),
        "got {:?}",
        issues
    );
}

// Silence unused imports in some configurations.
#[allow(dead_code)]
fn _use() {
    let _ = (ResponseRef::default(), StateEvent::default());
}
