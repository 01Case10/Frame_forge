# Archived: GDScript runtime (retired 2026-10-23)

`behavior_player.gd` here is the Phase-3 GDScript reimplementation of the
FrameForge runtime (tick, condition evaluation, momentum blending). It was
retired when the editor was made 1:1 with the Rust pipeline:

- **All evaluation logic lives in the Rust core.** The only
  `BehaviorPlayer` is the GDExtension class
  (`rust/frameforge-godot`, shipped in `addons/frameforge/bin/`), which
  the editor Preview, `exit_gate/run_gate.gd`, and `scenario_player.gd`
  now drive via `load_behavior(json_path)`.
- The GDScript classes that remain in `addons/frameforge/runtime/`
  (`FFCondition`, `FrameState`, …) are the editor's *document model* —
  data the editor edits and serializes — not an evaluator.
- `tests/phase{1,2,3}_runner.*` tested this GDScript runtime (incl. its
  `register_custom_condition` API, which the Rust player does not expose
  the same way). They are kept for reference only and no longer run;
  coverage lives in the Rust core test suite, the GDExtension bridge
  tests (`rust/godot_test/`), and the round-trip gate (`tools/`).

The archived player's `class_name` line was removed so the global
`BehaviorPlayer` name resolves to the native class alone.
