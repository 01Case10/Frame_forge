#!/usr/bin/env python3
"""Round-trip gate (part 2 of 2): semantic diff of original behavior JSONs
against the editor's load->save output.

A key missing on one side is accepted only when the present side's value
equals the Rust serde default for that field (absence == default in the
canonical schema). Everything else must match exactly (numbers within
float tolerance). Any other difference is a real fidelity loss and fails.

Usage: python3 tools/roundtrip_diff.py <orig_dir> <roundtripped_dir>
"""
import json
import os
import sys

F32_MAX = 3.4028235e38

COND_DEFAULTS = {
    "type": "on_complete",
    "input_actions": [],
    "input_mode": "any_pressed",
    "param_name": "",
    "param_op": "eq",
    "param_value": 0.0,
    "event_name": "",
    "target_machine_name": "",
    "target_state_name": "",
    "custom_name": "",
    "buffer_ticks": 0,
    "stick_radius_min": 0.0,
    "stick_radius_max": F32_MAX,
    "stick_angle_vs": "facing",
    "stick_angle_min_deg": 0.0,
    "stick_angle_max_deg": 180.0,
    "all_of": [],
    "any_of": [],
}

PARAM_DEFAULTS = {"type": "float", "default_value": 0.0}

STEER_DEFAULTS = {
    # SteerConfig / TurnModel / TurnTier: every numeric defaults to 0.0.
    "accel_forward": 0.0,
    "accel_side": 0.0,
    "accel_backward": 0.0,
    "backward_until_zero": False,
    "accel_along_velocity": 0.0,
    "speed_cap": 0.0,
    "speed_cap_per_radius": 0.0,
    "speed_min": 0.0,
    "enter_impact_speed": 0.0,
    "decel_above_cap": 0.0,
    "max_speed": 0.0,
    "decay": 0.0,
    "gravity": 0.0,
    "terminal_velocity": 0.0,
    "face_mode": "keep",
    "deadzone_deg": 0.0,
    "accel_near_frac": 0.0,
    "accel_far_frac": 0.0,
    "far_angle_deg": 0.0,
    "max_angle_deg": 0.0,
    "tiers": [],
    # TurnTier speed_max / cap_base are required in the Rust schema (no
    # serde default): absence on either side is a real difference.
    "cap_per_speed": 0.0,
    "cap_per_radius": 0.0,
    "cap_min": 0.0,
    "cap_max": 0.0,
    "quickturn_angle_deg": 0.0,
    "quickturn_rate_deg": 0.0,
    "enter_keep_horizontal": True,
    "enter_vy": "keep",
}

GENERIC_DEFAULTS = {
    # transitions
    "momentum": "cut",
    "blend_frames": 3,
    "fire_event": "",
    "silent": False,
    "target_behavior_name": "",
    "on_fire_params": [],
    "source_tag": "",
    # states
    "enter_params": [],
    "logic": "",
    "group_name": "",
    "editor_position": [0.0, 0.0],
    "min_value": 0.0,
    "max_value": 1.0,
    "steer": None,
    # responses are written as null when unset
    "resp_floor": None,
    "resp_ceiling": None,
    "resp_wall": None,
    "default_resp_floor": None,
    "default_resp_ceiling": None,
    "default_resp_wall": None,
    # behavior
    "spin_detect": None,
    "on_enter_event": "",
    "on_exit_event": "",
    "behavior_transitions": [],
    "parameters": [],
    "editor_comments": [],
}

problems = []


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def values_equal(a, b):
    if is_num(a) and is_num(b):
        return abs(float(a) - float(b)) <= 1e-6 * max(1.0, abs(float(a)), abs(float(b)))
    return a == b


def defaults_for(ctx):
    if ctx == "condition":
        return COND_DEFAULTS
    if ctx == "parameter":
        return PARAM_DEFAULTS
    if ctx == "steer":
        return STEER_DEFAULTS
    return GENERIC_DEFAULTS


def child_context(ctx, key):
    if key == "condition" or (ctx == "condition" and key in ("all_of", "any_of")):
        return "condition"
    if key == "parameters":
        return "parameter"
    if key == "steer" or ctx == "steer":
        return "steer"
    return ctx


def is_default(value, ctx, key):
    """True when `value` carries no information beyond the schema default
    for `key`: it equals the recorded default, or it is a container whose
    every entry is itself default-valued (e.g. a turn dict of zeros)."""
    d = defaults_for(ctx).get(key, _MISSING)
    if d is not _MISSING and values_equal(value, d):
        return True
    if isinstance(value, dict):
        sub = child_context(ctx, key)
        return all(is_default(v, sub, k) for k, v in value.items())
    if isinstance(value, list):
        return len(value) == 0
    return False


def compare(a, b, path, ctx):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            child_ctx = child_context(ctx, k)
            if k not in a:
                if not is_default(b[k], child_ctx, k):
                    problems.append(f"ADDED {path}/{k} = {b[k]!r} (no default)")
            elif k not in b:
                if not is_default(a[k], child_ctx, k):
                    problems.append(f"LOST {path}/{k} = {a[k]!r} (no default)")
            else:
                compare(a[k], b[k], f"{path}/{k}", child_ctx)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            problems.append(f"LEN {path}: {len(a)} != {len(b)}")
            return
        for i, (x, y) in enumerate(zip(a, b)):
            compare(x, y, f"{path}[{i}]", ctx)
    elif not values_equal(a, b):
        problems.append(f"CHANGED {path}: {a!r} -> {b!r}")


class _Missing:
    pass


_MISSING = _Missing()


def main():
    orig_dir, rt_dir = sys.argv[1], sys.argv[2]
    names = sorted(f for f in os.listdir(orig_dir) if f.endswith(".json"))
    total = 0
    for name in names:
        with open(os.path.join(orig_dir, name)) as f:
            orig = json.load(f)
        rt_path = os.path.join(rt_dir, name)
        if not os.path.exists(rt_path):
            problems.append(f"MISSING round-trip output: {name}")
            continue
        with open(rt_path) as f:
            rt = json.load(f)
        before = len(problems)
        compare(orig, rt, name, "generic")
        total += len(problems) - before
        print(f"{name}: {'OK' if len(problems) == before else 'DIFF'}")
    total = len(problems)
    for p in problems:
        print(" ", p)
    print(f"round-trip diff: {total} problem(s) across {len(names)} files")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
