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

## Changelog

- 2026-11-03: demo menu — `menu.tscn`/`menu.gd` is now the main scene
  (F5), listing the 13 exit-gate scenario playbacks; `scenario_player.gd`
  accepts the menu's SceneTree metas and returns to the menu when done
  (Esc backs out early). New `tools/install_rust.ps1`: idempotent Windows
  Rust toolchain setup (winget or rustup-init, MSVC linker check).
  Verified headless under Godot 4.6: menu runs clean, walk_straight
  playback completes through the menu path.
- 2026-11-03: `tools/build_extension.ps1` — one-command Windows build:
  `cargo build -p frameforge-godot`, copies the DLL to
  `addons/frameforge/bin/`, registers the `windows.x86_64` entries in
  `frameforge.gdextension` (idempotent). `tools/install_rust.ps1` no
  longer fails the setup when `rustup default` hits the Windows
  self-update bug (rust-lang/rustup#3709); cargo/rustc are verified
  directly instead.
- 2026-11-03: free-play `playground.tscn` + `playground.gd` (menu buttons
  "Playground: Mario 64" / "Playground: Odyssey"): small platforming
  level (floor, walls, stairs, floaters, pillars), follow camera with
  right-stick orbit, gamepad + keyboard input. KEY FINDING: the two
  movesets use different native units — move.json is meters (jump
  1.45 m), smo_movement.json is SMO decomp centimeters (run cap
  14 u/tick = 8.4 m/s, jump ~328 u = 3.3 m; the committed
  smo_showcase plays it unscaled, i.e. 100x wrong). The playground
  builds level/capsule/camera in the moveset's native units (unit
  1.0 / 100.0). sm64 gets supplemental gravity (move.json has no fall
  state); camera-relative controls for both (smo via camera_yaw_deg =
  rig_yaw + 180; sm64 via rotating which ff_* action is pressed, since
  its states are not camera_relative). Verified headless: both move
  camera-away on stick-up, jump/land, menu buttons navigate.
- 2026-11-03: `playground_animator.gd` — procedural placeholder
  character (blob body, eyes, wearable cap) with exaggerated
  squash-and-stretch for the playground. All 76 SMO states (both
  machines) + 9 SM64 states map to poses (scale targets, lean/tilt,
  yaw/pitch spins, bob, wobble); transitions spring through an
  underdamped squash spring so landings overshoot; cap leaves the head
  and flies a canned arc on throws, returns on recall. Verified
  headless: 85/85 states mapped, run/jump/land squash values hit their
  pose targets, cap throw/recall cycle works.
- 2026-11-03: `tests/playground_anim_test.tscn` — 15 headless tests,
  all passing. Unit: 85/85 state coverage, pre-setup guards, slam
  spring settles, yaw/pitch spins decay after their state ends, cap
  throw/recall always completes, exact capsule-lowest-point clearance
  >= 0 across every pose (worst exactly 0.0000), facing follows
  velocity. Integration: scripted gameplay per moveset, per-frame
  ground clearance + >=6 states exercised + no unmapped states (skips
  gracefully without the built extension). Testing caught a real bug:
  the squash pivot was at the body center (stretch poses would have
  buried the feet); now pivots at the feet. Also fixed the clearance
  probe itself: AABB is conservative under tilt, so body_min_y() now
  computes the true capsule lowest point.
- 2026-11-03: Playground control fixes (Joey: left/right inverted,
  can't steer while moving forward, stuck on walls). Three root
  causes, all verified headless:
  1. SMO left/right inverted: the core's stick frame is mirrored vs
     the Godot camera (right=(cos,-sin) is left-handed in xz), so no
     camera yaw can align both axes. `playground.gd` now negates the
     x fed to the core (ui_left/ui_right swapped); sm64's ff_*
     mapping was already correct and is untouched.
  2. Can't steer at speed: in `apply_steer`, when hspeed >= speed_cap
     the accel block (which reorients velocity into the facing frame)
     was skipped, freezing the velocity direction at max speed while
     the facing kept turning. The core now rotates vh by the facing
     turn delta when at the cap, so Mario carves at 14 u/tick.
     Verified: full-speed run turns 180° -> 163° on slight-right.
  3. Wall push: Mario spawned at y=1.5U (airborne), so he fell
     through coyote/fall (whose quickturn mis-oriented him ~17°)
     instead of grounding into idle->pivot. Spawn is now y=0.1U
     (grounded); pull-back from wall_push reliably escapes (verified:
     z -2260 -> -881 on pull-back). The run<->wall_push flicker while
     pressing into the wall is the transcribed behavior (velocity cut
     on entry breaks wall contact for a tick); acceptable for the
     playground.
  Also verified: sm64 push-right still moves +x (camera-right).
  All 53 frameforge-core Rust tests pass; all 15 Godot animator/
  playground tests pass.
