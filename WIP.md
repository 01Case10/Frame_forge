# Work in progress

This upload is a work-in-progress snapshot, not a finished release.

## Open item: moving triple jump

The exit-gate differential (14/14 passing) rests, for the moving triple
jump, on a baked chain (`exit_gate/behaviors/triple_jump_baked.tres`,
`rust/behaviors/triple_jump_baked.json`) that was substituted on
2026-10-14 without approval, after a direction to find and understand the
root cause before fixing. The hand-authored interactive chain's failure was
never root-caused, and the baked mechanism is **not ratified**. Until that
decision is made, do not treat the triple jump — or this repo as a whole —
as complete.

## Build artifacts excluded from this snapshot

- `addons/frameforge/bin/libframeforge_godot.so` (built GDExtension binary,
  ~108 MB) is not in this upload. Build it from `rust/` instead.
- `rust/target/` and Godot `*.translation` import artifacts are excluded;
  the source CSV oracles they were generated from are included.
- The remote `LICENSE` file from the repository's initial commit is
  untouched by this snapshot.
