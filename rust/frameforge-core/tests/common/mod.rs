//! Shared builders + harness for the ported phase suites.
//! Mirrors the `TCase` helpers in `tests/phase{1,2,3}_runner.gd`.

#![allow(dead_code)]
#![allow(clippy::field_reassign_with_default)]

use frameforge_core::input::TickInput;
use frameforge_core::tick::{ContactState, Runtime};
use frameforge_core::vec3::ZERO;
use frameforge_core::vec3::{Vec3, UP};
use frameforge_core::{
    Condition, ConditionType, EasingCurve, EventTrigger, FrameBehavior, FrameState, InputMode,
    Momentum, Op, ParamType, ParamValue, Parameter, ResponseRef, StateEvent, SubStateMachine,
    Transition,
};
use std::collections::{HashMap, HashSet};

pub fn mk_state(name: &str, disp: f32, dir: Vec3, dur: u32) -> FrameState {
    FrameState {
        state_name: name.to_string(),
        displacement: disp,
        direction: dir.to_array(),
        duration_frames: dur,
        ..Default::default()
    }
}

pub fn on_complete_row(target: &str) -> Transition {
    Transition {
        condition: Condition {
            cond_type: ConditionType::OnComplete,
            ..Default::default()
        },
        target_state_name: target.to_string(),
        ..Default::default()
    }
}

pub fn c_input(actions: &[&str], mode: InputMode) -> Condition {
    Condition {
        cond_type: ConditionType::OnInput,
        input_actions: actions.iter().map(|s| s.to_string()).collect(),
        input_mode: mode,
        ..Default::default()
    }
}

pub fn c_var(name: &str, op: Op, val: ParamValue) -> Condition {
    Condition {
        cond_type: ConditionType::OnVariable,
        param_name: name.to_string(),
        param_op: op,
        param_value: val,
        ..Default::default()
    }
}

pub fn c_event(name: &str) -> Condition {
    Condition {
        cond_type: ConditionType::OnEvent,
        event_name: name.to_string(),
        ..Default::default()
    }
}

pub fn c_state(machine: &str, state: &str) -> Condition {
    Condition {
        cond_type: ConditionType::OnState,
        target_machine_name: machine.to_string(),
        target_state_name: state.to_string(),
        ..Default::default()
    }
}

pub fn c_custom(name: &str) -> Condition {
    Condition {
        cond_type: ConditionType::OnCustom,
        custom_name: name.to_string(),
        ..Default::default()
    }
}

pub fn row_to(cond: Condition, target: &str, momentum: Momentum, blend: u32) -> Transition {
    Transition {
        condition: cond,
        target_state_name: target.to_string(),
        momentum,
        blend_frames: blend,
        ..Default::default()
    }
}

pub fn mk_resp(target: &str, min_speed: f32, rearm: u32) -> ResponseRef {
    ResponseRef {
        target_state_name: target.to_string(),
        min_incoming_speed: min_speed,
        rearm_ticks: rearm,
        ..Default::default()
    }
}

pub fn mk_event(name: &str, trig: EventTrigger, frame: u32) -> StateEvent {
    StateEvent {
        event_name: name.to_string(),
        trigger: trig,
        frame,
    }
}

pub fn mk_machine(name: &str, states: Vec<FrameState>, entry: &str) -> SubStateMachine {
    SubStateMachine {
        machine_name: name.to_string(),
        states,
        entry_state_name: entry.to_string(),
        ..Default::default()
    }
}

pub fn mk_machine_empty(name: &str) -> SubStateMachine {
    SubStateMachine {
        machine_name: name.to_string(),
        ..Default::default()
    }
}

pub fn mk_behavior(machines: Vec<SubStateMachine>, name: &str) -> FrameBehavior {
    FrameBehavior {
        behavior_name: name.to_string(),
        sub_machines: machines,
        ..Default::default()
    }
}

pub fn add_param(bh: &mut FrameBehavior, name: &str, ptype: ParamType, def: ParamValue) {
    bh.parameters.push(Parameter {
        name: name.to_string(),
        ptype,
        default_value: def,
    });
}

pub fn linear_curve(p0: [f32; 2], p1: [f32; 2]) -> EasingCurve {
    use frameforge_core::CurvePoint;
    EasingCurve {
        points: vec![
            CurvePoint {
                pos: p0,
                left_tangent: 0.0,
                right_tangent: 0.0,
            },
            CurvePoint {
                pos: p1,
                left_tangent: 0.0,
                right_tangent: 0.0,
            },
        ],
        min_value: 0.0,
        max_value: 1.0,
    }
}

/// Input with held actions (strength 1.0 each).
pub fn held(actions: &[&str]) -> TickInput {
    let mut h = HashSet::new();
    let mut s = HashMap::new();
    for a in actions {
        h.insert(a.to_string());
        s.insert(a.to_string(), 1.0);
    }
    TickInput {
        held: h,
        strengths: s,
    }
}

pub struct Harness {
    pub rt: Runtime,
    pub pos: Vec3,
}

impl Harness {
    pub fn new(bh: FrameBehavior) -> Self {
        Self {
            rt: Runtime::new(bh),
            pos: ZERO,
        }
    }

    pub fn new_at(bh: FrameBehavior, pos: Vec3) -> Self {
        Self {
            rt: Runtime::new(bh),
            pos,
        }
    }

    /// Plain tick (no physics): accumulate the delta.
    pub fn tick(&mut self, input: &TickInput) -> Vec3 {
        let d = self.rt.tick_delta(input);
        self.pos = self.pos + d;
        self.rt.tick_contact(&ContactState::default());
        d
    }

    /// Tick with minimal flat-world physics: floor plane y=0.5, wall face
    /// x=4.7 (capsule r=0.3). Mirrors the phase-2 collision test arenas.
    pub fn tick_physics(&mut self, input: &TickInput) -> Vec3 {
        let d = self.rt.tick_delta(input);
        let mut new_pos = self.pos + d;
        let mut contact = ContactState::default();
        if new_pos.y <= 0.5 {
            new_pos.y = 0.5;
            contact.floor = true;
            contact.floor_normal = UP;
        }
        if new_pos.x >= 4.7 {
            if d.x > 0.0 {
                new_pos.x = 4.7;
            }
            contact.wall = true;
            contact.wall_normal = Vec3::new(-1.0, 0.0, 0.0);
        }
        self.pos = new_pos;
        self.rt.tick_contact(&contact);
        d
    }

    pub fn state(&self, machine: &str) -> String {
        self.rt
            .track_states()
            .into_iter()
            .find(|(m, _, _)| m == machine)
            .map(|(_, s, _)| s)
            .unwrap_or_else(|| "<none>".to_string())
    }
}
