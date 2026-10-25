//! Pure-logic validation for FrameForge behaviors.
//! Port of `addons/frameforge/editor/ff_validator.gd`.
//! No editor dependencies.

use crate::logic::BUILTIN_LOGIC_NAMES;
use crate::{
    Condition, ConditionType, DirectionSource, DisplacementSource, EventTrigger, FrameBehavior,
    FrameState, InputMode, Momentum, ParamAssign, ResponseRef, SteerConfig, SubStateMachine,
    Transition, STATE_STEP_PARAM,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

#[derive(Debug, Clone)]
pub struct Issue {
    pub severity: Severity,
    pub message: String,
    pub machine: Option<String>,
    pub state: Option<String>,
}

fn issue(
    issues: &mut Vec<Issue>,
    severity: Severity,
    message: String,
    machine: Option<&str>,
    state: Option<&str>,
) {
    issues.push(Issue {
        severity,
        message,
        machine: machine.map(|s| s.to_string()),
        state: state.map(|s| s.to_string()),
    });
}

pub fn validate_behavior(bh: &FrameBehavior) -> Vec<Issue> {
    validate_behavior_with_logics(bh, BUILTIN_LOGIC_NAMES)
}

/// Like [`validate_behavior`], with a custom set of known state-logic names
/// (for embedders that register their own via `register_state_logic`).
pub fn validate_behavior_with_logics(bh: &FrameBehavior, known_logics: &[&str]) -> Vec<Issue> {
    let mut issues = Vec::new();
    check_parameters(bh, &mut issues);
    for m in &bh.sub_machines {
        validate_machine(bh, m, known_logics, &mut issues);
    }
    check_behavior_transitions(bh, &mut issues);
    check_parallel_axes(bh, &mut issues);
    issues
}

fn check_parameters(bh: &FrameBehavior, issues: &mut Vec<Issue>) {
    let mut seen = std::collections::HashSet::new();
    for p in &bh.parameters {
        if p.name.is_empty() {
            issue(
                issues,
                Severity::Warning,
                "Parameter with empty name.".to_string(),
                None,
                None,
            );
        } else if !seen.insert(p.name.clone()) {
            issue(
                issues,
                Severity::Warning,
                format!("Duplicate parameter name \"{}\".", p.name),
                None,
                None,
            );
        }
    }
}

fn find_state<'a>(m: &'a SubStateMachine, name: &str) -> Option<&'a FrameState> {
    m.states.iter().find(|s| s.state_name == name)
}

fn validate_machine(
    bh: &FrameBehavior,
    m: &SubStateMachine,
    known_logics: &[&str],
    issues: &mut Vec<Issue>,
) {
    let mn = m.machine_name.as_str();
    if m.states.is_empty() {
        issue(
            issues,
            Severity::Warning,
            format!("Sub-machine \"{}\" has no states.", mn),
            Some(mn),
            None,
        );
        return;
    }
    if m.entry_state_name.is_empty() {
        issue(
            issues,
            Severity::Error,
            format!("Sub-machine \"{}\" has no entry state.", mn),
            Some(mn),
            None,
        );
    } else if find_state(m, &m.entry_state_name).is_none() {
        issue(
            issues,
            Severity::Error,
            format!(
                "Sub-machine \"{}\": entry state \"{}\" is not in its state list.",
                mn, m.entry_state_name
            ),
            Some(mn),
            None,
        );
    }

    let mut seen_names = std::collections::HashSet::new();
    for s in &m.states {
        if !seen_names.insert(s.state_name.clone()) {
            issue(
                issues,
                Severity::Error,
                format!(
                    "Sub-machine \"{}\": duplicate state name \"{}\".",
                    mn, s.state_name
                ),
                Some(mn),
                Some(&s.state_name),
            );
        }
    }

    let reachable = reachable_states(m);
    for s in &m.states {
        validate_state(bh, m, s, &reachable, known_logics, issues);
    }

    // Impact-source reachability.
    let mut collision_targets = std::collections::HashSet::new();
    for s in &m.states {
        for r in [
            &s.resp_floor,
            &s.resp_ceiling,
            &s.resp_wall,
            &m.default_resp_floor,
            &m.default_resp_ceiling,
            &m.default_resp_wall,
        ]
        .into_iter()
        .flatten()
        {
        if !r.target_state_name.is_empty() {
                collision_targets.insert(r.target_state_name.clone());
                if find_state(m, &r.target_state_name).is_none() {
                    issue(
                        issues,
                        Severity::Error,
                        format!(
                            "State \"{}\": collision response targets unknown state \"{}\".",
                            s.state_name, r.target_state_name
                        ),
                        Some(mn),
                        Some(&s.state_name),
                    );
                }
            }
        }
    }
    for s in &m.states {
        let impact_fed = s.direction_source == DirectionSource::ImpactNormal
            || s.direction_source == DirectionSource::Reflected
            || s.displacement_source == DisplacementSource::Incoming;
        if impact_fed && !collision_targets.contains(&s.state_name) {
            issue(
                issues,
                Severity::Warning,
                format!(
                    "State \"{}\" uses impact/incoming sources but no collision response targets it.",
                    s.state_name
                ),
                Some(mn),
                Some(&s.state_name),
            );
        }
    }
}

fn validate_state(
    bh: &FrameBehavior,
    m: &SubStateMachine,
    s: &FrameState,
    reachable: &std::collections::HashSet<String>,
    known_logics: &[&str],
    issues: &mut Vec<Issue>,
) {
    let mn = m.machine_name.as_str();
    let sn = s.state_name.as_str();
    if s.duration_frames == 0 {
        issue(
            issues,
            Severity::Error,
            format!("State \"{}\" has zero/negative duration.", sn),
            Some(mn),
            Some(sn),
        );
    }
    if s.direction_source == DirectionSource::Author && s.displacement > 0.0 {
        let len = (s.direction[0] * s.direction[0]
            + s.direction[1] * s.direction[1]
            + s.direction[2] * s.direction[2])
            .sqrt();
        if (len - 1.0).abs() > 0.01 {
            issue(
                issues,
                Severity::Warning,
                format!(
                    "State \"{}\" direction is not normalized (length {:.3}).",
                    sn, len
                ),
                Some(mn),
                Some(sn),
            );
        }
    }
    if !reachable.contains(&s.state_name) {
        issue(
            issues,
            Severity::Warning,
            format!("State \"{}\" is unreachable from the entry state.", sn),
            Some(mn),
            Some(sn),
        );
    }

    // Events.
    let mut names = std::collections::HashSet::new();
    for ev in &s.events {
        if ev.event_name.is_empty() {
            issue(
                issues,
                Severity::Warning,
                format!("State \"{}\" has an event with an empty name.", sn),
                Some(mn),
                Some(sn),
            );
        } else if !names.insert(ev.event_name.clone()) {
            issue(
                issues,
                Severity::Warning,
                format!(
                    "State \"{}\" fires \"{}\" more than once.",
                    sn, ev.event_name
                ),
                Some(mn),
                Some(sn),
            );
        }
        if ev.trigger == EventTrigger::OnFrame && ev.frame >= s.duration_frames.max(1) {
            issue(
                issues,
                Severity::Error,
                format!(
                    "State \"{}\": event \"{}\" frame {} out of range (0..{}).",
                    sn,
                    ev.event_name,
                    ev.frame,
                    s.duration_frames.max(1) - 1
                ),
                Some(mn),
                Some(sn),
            );
        }
    }

    // G-4: state enter_params.
    validate_param_assigns(&s.enter_params, mn, sn, "enter_params", issues);
    // G-5: steering sanity.
    if let Some(st) = &s.steer {
        validate_steer(st, mn, sn, issues);
    }
    // G-6: state logic sanity.
    if let Some(name) = &s.logic {
        if !known_logics.contains(&name.as_str()) {
            issue(
                issues,
                Severity::Error,
                format!(
                    "State \"{}\" names unknown state logic \"{}\" (known: {}).",
                    sn,
                    name,
                    known_logics.join(", ")
                ),
                Some(mn),
                Some(sn),
            );
        }
        if s.steer.is_some() {
            issue(
                issues,
                Severity::Warning,
                format!(
                    "State \"{}\" sets both `steer` and `logic`; the logic owns the delta and `steer` is ignored.",
                    sn
                ),
                Some(mn),
                Some(sn),
            );
        }
    }

    // Transition rows.
    if s.transitions.is_empty() {
        issue(
            issues,
            Severity::Error,
            format!(
                "State \"{}\" has no transition rows (terminal states are not allowed).",
                sn
            ),
            Some(mn),
            Some(sn),
        );
        return;
    }
    let mut trap = true;
    for row in &s.transitions {
        let target_name = row.target_state_name.as_str();
        if target_name.is_empty()
            && row.target_behavior_name.is_empty()
            && row.fire_event.is_empty()
        {
            issue(
                issues,
                Severity::Error,
                format!(
                    "State \"{}\" has an unwired transition row (no target, no event).",
                    sn
                ),
                Some(mn),
                Some(sn),
            );
        }
        if !target_name.is_empty() && find_state(m, target_name).is_none() {
            issue(
                issues,
                Severity::Error,
                format!(
                    "State \"{}\": row targets unknown state \"{}\".",
                    sn, target_name
                ),
                Some(mn),
                Some(sn),
            );
        }
        if row_leaves(row, s) {
            trap = false;
        }
        validate_condition(bh, m, s, row, issues);
        if row.momentum == Momentum::Preserve && !target_name.is_empty() {
            if let Some(t) = find_state(m, target_name) {
                if t.direction_source == DirectionSource::Entry
                    || t.displacement_source == DisplacementSource::Entry
                {
                    issue(
                        issues,
                        Severity::Warning,
                        format!(
                            "Row in \"{}\" → \"{}\": Preserve momentum is redundant with the target's ENTRY sources.",
                            sn, target_name
                        ),
                        Some(mn),
                        Some(sn),
                    );
                }
            }
        }
    }
    for r in [
        &s.resp_floor,
        &s.resp_ceiling,
        &s.resp_wall,
        &m.default_resp_floor,
        &m.default_resp_ceiling,
        &m.default_resp_wall,
    ]
    .into_iter()
    .flatten()
    {
        if response_leaves(r, s) {
            trap = false;
        }
    }
    if trap {
        issue(
            issues,
            Severity::Warning,
            format!(
                "State \"{}\" looks like a trap: no row or collision response leaves it.",
                sn
            ),
            Some(mn),
            Some(sn),
        );
    }

    if s.direction_source == DirectionSource::Input
        && s.input_left.is_empty()
        && s.input_right.is_empty()
        && s.input_forward.is_empty()
        && s.input_back.is_empty()
    {
        issue(
            issues,
            Severity::Warning,
            format!(
                "State \"{}\" uses Input direction but no input actions are assigned.",
                sn
            ),
            Some(mn),
            Some(sn),
        );
    }
}

fn row_leaves(row: &Transition, s: &FrameState) -> bool {
    if !row.target_behavior_name.is_empty() {
        return true;
    }
    !row.target_state_name.is_empty() && row.target_state_name != s.state_name
}

fn response_leaves(resp: &ResponseRef, s: &FrameState) -> bool {
    if !resp.target_behavior_name.is_empty() {
        return true;
    }
    !resp.target_state_name.is_empty() && resp.target_state_name != s.state_name
}

fn validate_condition(
    bh: &FrameBehavior,
    m: &SubStateMachine,
    s: &FrameState,
    row: &Transition,
    issues: &mut Vec<Issue>,
) {
    validate_condition_inner(bh, m, s, &row.condition, issues);
    let mn = m.machine_name.as_str();
    let sn = s.state_name.as_str();
    // G-4: blackboard writes are validated for every row type.
    validate_param_assigns(&row.on_fire_params, mn, sn, "on_fire_params", issues);
}

fn validate_condition_inner(
    bh: &FrameBehavior,
    m: &SubStateMachine,
    s: &FrameState,
    c: &Condition,
    issues: &mut Vec<Issue>,
) {
    // Phase C: composites recurse; an empty composite never fires.
    if !c.all_of.is_empty() || !c.any_of.is_empty() {
        if c.all_of.is_empty() && c.any_of.is_empty() {
            // unreachable
        }
        for sub in c.all_of.iter().chain(c.any_of.iter()) {
            validate_condition_inner(bh, m, s, sub, issues);
        }
        if c.all_of.iter().chain(c.any_of.iter()).count() == 0 {
            let mn = m.machine_name.as_str();
            let sn = s.state_name.as_str();
            issue(
                issues,
                Severity::Warning,
                format!("State \"{}\": empty composite condition never fires.", sn),
                Some(mn),
                Some(sn),
            );
        }
        return;
    }
    let mn = m.machine_name.as_str();
    let sn = s.state_name.as_str();
    match c.cond_type {
        ConditionType::OnInput => {
            if c.input_actions.is_empty() {
                issue(
                    issues,
                    Severity::Warning,
                    format!("State \"{}\": On Input row has no actions assigned.", sn),
                    Some(mn),
                    Some(sn),
                );
            }
            // G-1: buffering only applies to AnyPressed.
            if c.buffer_ticks > 0 && c.input_mode != InputMode::AnyPressed {
                issue(
                    issues,
                    Severity::Warning,
                    format!(
                        "State \"{}\": buffer_ticks is set but only AnyPressed rows are buffered; the value is ignored.",
                        sn
                    ),
                    Some(mn),
                    Some(sn),
                );
            }
        }
        ConditionType::OnStick => {
            if c.stick_radius_min < 0.0
                || c.stick_radius_max < c.stick_radius_min
                || c.stick_angle_min_deg < 0.0
                || c.stick_angle_max_deg < c.stick_angle_min_deg
                || c.stick_angle_max_deg > 180.0
            {
                issue(
                    issues,
                    Severity::Warning,
                    format!(
                        "State \"{}\": On Stick row has an inconsistent radius/angle range.",
                        sn
                    ),
                    Some(mn),
                    Some(sn),
                );
            }
        }
        ConditionType::OnVariable => {
            // G-3: state_step is a reserved engine param, always valid.
            let known = c.param_name == STATE_STEP_PARAM
                || bh.parameters.iter().any(|p| p.name == c.param_name);
            if !known {
                issue(
                    issues,
                    Severity::Warning,
                    format!(
                        "State \"{}\": On Variable row references unknown parameter \"{}\".",
                        sn, c.param_name
                    ),
                    Some(mn),
                    Some(sn),
                );
            }
        }
        ConditionType::OnEvent => {
            if c.event_name.is_empty() {
                issue(
                    issues,
                    Severity::Warning,
                    format!("State \"{}\": On Event row has no event name.", sn),
                    Some(mn),
                    Some(sn),
                );
            }
        }
        ConditionType::OnState => {
            if c.target_machine_name.is_empty() || c.target_state_name.is_empty() {
                issue(
                    issues,
                    Severity::Warning,
                    format!(
                        "State \"{}\": On State row is missing its machine/state.",
                        sn
                    ),
                    Some(mn),
                    Some(sn),
                );
            } else {
                let tm = bh
                    .sub_machines
                    .iter()
                    .find(|om| om.machine_name == c.target_machine_name);
                match tm {
                    None => issue(
                        issues,
                        Severity::Warning,
                        format!(
                            "State \"{}\": On State row targets unknown machine \"{}\".",
                            sn, c.target_machine_name
                        ),
                        Some(mn),
                        Some(sn),
                    ),
                    Some(tm) => {
                        if find_state(tm, &c.target_state_name).is_none() {
                            issue(
                                issues,
                                Severity::Warning,
                                format!(
                                    "State \"{}\": On State row targets unknown state \"{}\".",
                                    sn, c.target_state_name
                                ),
                                Some(mn),
                                Some(sn),
                            );
                        }
                    }
                }
            }
        }
        ConditionType::OnCustom => {
            if c.custom_name.is_empty() {
                issue(
                    issues,
                    Severity::Warning,
                    format!("State \"{}\": On Custom row has no name.", sn),
                    Some(mn),
                    Some(sn),
                );
            }
        }
        ConditionType::OnComplete => {}
    }
}

/// G-4: validate blackboard writes (transition on_fire_params / state
/// enter_params).
fn validate_param_assigns(
    assigns: &[ParamAssign],
    mn: &str,
    sn: &str,
    field: &str,
    issues: &mut Vec<Issue>,
) {
    for a in assigns {
        match a {
            ParamAssign::Set { name, .. } => {
                if name.is_empty() {
                    issue(
                        issues,
                        Severity::Warning,
                        format!(
                            "State \"{}\": {} has a Set assign with an empty parameter name.",
                            sn, field
                        ),
                        Some(mn),
                        Some(sn),
                    );
                }
            }
            ParamAssign::Countdown { name, ticks } => {
                if name.is_empty() {
                    issue(
                        issues,
                        Severity::Warning,
                        format!(
                            "State \"{}\": {} has a Countdown assign with an empty parameter name.",
                            sn, field
                        ),
                        Some(mn),
                        Some(sn),
                    );
                }
                if *ticks == 0 {
                    issue(
                        issues,
                        Severity::Warning,
                        format!(
                            "State \"{}\": {} countdown \"{}\" has 0 ticks (never positive).",
                            sn, field, name
                        ),
                        Some(mn),
                        Some(sn),
                    );
                }
            }
        }
    }
}

/// G-5: sanity checks on a steering config.
fn validate_steer(st: &SteerConfig, mn: &str, sn: &str, issues: &mut Vec<Issue>) {
    let mut w = |msg: String| {
        issue(
            issues,
            Severity::Warning,
            format!("State \"{}\": {}", sn, msg),
            Some(mn),
            Some(sn),
        )
    };
    if st.decay < 0.0 || st.decay >= 1.0 {
        w(format!(
            "steer decay {} is outside [0, 1); it is ignored.",
            st.decay
        ));
    }
    if st.gravity < 0.0 {
        w(format!(
            "steer gravity {} is negative (positive = downward); check the sign.",
            st.gravity
        ));
    }
    if st.terminal_velocity < 0.0 {
        w(format!(
            "steer terminal_velocity {} is negative; it is ignored.",
            st.terminal_velocity
        ));
    }
    let mut prev_max = -1.0f32;
    for (i, tier) in st.turn.tiers.iter().enumerate() {
        if tier.speed_max <= prev_max {
            w(format!(
                "steer turn tier {} speed_max {} is not above the previous tier's; tiers are first-match-wins.",
                i, tier.speed_max
            ));
        }
        prev_max = tier.speed_max;
        if tier.cap_base < 0.0 {
            w(format!("steer turn tier {} has a negative cap_base.", i));
        }
    }
    if st.turn.max_angle_deg > 0.0 && st.turn.max_angle_deg < st.turn.deadzone_deg {
        w("steer turn max_angle_deg is below deadzone_deg; nothing can turn.".to_string());
    }
    if st.quickturn_angle_deg < 0.0 || st.quickturn_rate_deg < 0.0 {
        w("steer quickturn angle/rate must be >= 0.".to_string());
    }
}

fn reachable_states(m: &SubStateMachine) -> std::collections::HashSet<String> {
    let mut seen = std::collections::HashSet::new();
    if m.entry_state_name.is_empty() {
        return seen;
    }
    let mut stack: Vec<&FrameState> = Vec::new();
    if let Some(e) = find_state(m, &m.entry_state_name) {
        stack.push(e);
    }
    while let Some(s) = stack.pop() {
        if !seen.insert(s.state_name.clone()) {
            continue;
        }
        for row in &s.transitions {
            if !row.target_state_name.is_empty() {
                if let Some(t) = find_state(m, &row.target_state_name) {
                    stack.push(t);
                }
            }
        }
        // Contact responses also reach states.
        for r in [&s.resp_floor, &s.resp_ceiling, &s.resp_wall]
            .into_iter()
            .flatten()
        {
            if !r.target_state_name.is_empty() {
                if let Some(t) = find_state(m, &r.target_state_name) {
                    stack.push(t);
                }
            }
        }
    }
    seen
}

fn check_behavior_transitions(bh: &FrameBehavior, issues: &mut Vec<Issue>) {
    for row in &bh.behavior_transitions {
        if row.target_behavior_name.is_empty() && row.fire_event.is_empty() {
            issue(
                issues,
                Severity::Error,
                "Behavior transition has no target behavior and no event.".to_string(),
                None,
                None,
            );
        }
    }
}

fn check_parallel_axes(bh: &FrameBehavior, issues: &mut Vec<Issue>) {
    let machines = &bh.sub_machines;
    for i in 0..machines.len() {
        for j in (i + 1)..machines.len() {
            let a = &machines[i];
            let b = &machines[j];
            let axes_a = authored_axes(a);
            let axes_b = authored_axes(b);
            for (ax, name) in [("x", "X"), ("y", "Y"), ("z", "Z")] {
                let has_a = match ax {
                    "x" => axes_a.0,
                    "y" => axes_a.1,
                    _ => axes_a.2,
                };
                let has_b = match ax {
                    "x" => axes_b.0,
                    "y" => axes_b.1,
                    _ => axes_b.2,
                };
                if has_a && has_b {
                    issue(
                        issues,
                        Severity::Warning,
                        format!(
                            "Sub-machines \"{}\" and \"{}\" both author displacement on the {} axis.",
                            a.machine_name, b.machine_name, name
                        ),
                        None,
                        None,
                    );
                }
            }
        }
    }
}

fn authored_axes(m: &SubStateMachine) -> (bool, bool, bool) {
    let mut axes = (false, false, false);
    for s in &m.states {
        if s.displacement <= 0.0 {
            continue;
        }
        if s.direction_source != DirectionSource::Author {
            continue;
        }
        let len = (s.direction[0] * s.direction[0]
            + s.direction[1] * s.direction[1]
            + s.direction[2] * s.direction[2])
            .sqrt();
        if len < 1e-9 {
            continue;
        }
        let (x, y, z) = (
            s.direction[0] / len,
            s.direction[1] / len,
            s.direction[2] / len,
        );
        if x.abs() > 0.5 {
            axes.0 = true;
        }
        if y.abs() > 0.5 {
            axes.1 = true;
        }
        if z.abs() > 0.5 {
            axes.2 = true;
        }
    }
    axes
}
