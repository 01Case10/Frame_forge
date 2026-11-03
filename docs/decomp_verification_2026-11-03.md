# Decomp verification — SMO example vs OdysseyDecomp (2026-11-03)

**Method:** cloned `MonsterDruide1/OdysseyDecomp` @ `696db2f`, used its own
`data/file_list.yml` ("Matching" = byte-identical vs the SMO 1.0.0 NSO, verified by
the project's `tools/check`). Compared each fully-matched player state source against
the corresponding state(s) in `rust/behaviors/smo_movement.json`.

**Scope limits (read first):**
- Shipped tuning *values* live in BYAML game data, not in the repo. The decomp verifies
  *structure* (which constants feed which logic, call order, thresholds) — numbers still
  come from the spec/datamined BYAML.
- `PlayerActorHakoniwa` (the top-level dispatcher) is 0% decompiled, so none of the
  938 transition *conditions* are verifiable here — only per-state behavior.
- Helper math in `rs::` (`ObjUtil`, `PlayerUtil`, `PlayerCollisionUtil`) is ~0–4%
  decompiled: for `jump_long`/`dive`, the decomp shows the call sequence and every
  constant passed in, but not the arithmetic inside `setupLongJumpVelocity`/`moveDivingJump`.
- **Correction to the 2026-11-03 coverage note:** `PlayerStateNormalWallSlide` (the actual
  wall-slide per-tick physics, "壁すべり") is 0% — only the `PlayerStateWallAir`
  Slide/Jump *dispatcher* is matched. Wall-slide physics is NOT verifiable.

## Verdicts

| Example state(s) | Decomp source | Verdict |
|---|---|---|
| `jump_long` | `PlayerStateLongJump` (100%) | ✓ structure matches; helper math unverifiable |
| `dive` | `PlayerStateHeadSliding` (100%) | ⚠ 3 divergences (D1–D3) |
| `jump_wall` | `PlayerStateNormalWallJump` (100%) | ✓ entry matches; ⚠ input blackout missing (D5) |
| `gp_stall`/`gp_fall`/`gp_land` | `PlayerStateHipDrop` (100%) | ✓ nerve structure; ⚠ 2 divergences (D6–D7) |
| `wall_slide` | `PlayerStateWallAir` dispatcher (100%) | ✓ dispatch only; slide physics unverifiable |
| `wall_push` | `PlayerJudgeWallPush` (100%) | ⚠ angle tolerances differ (D8) |
| `crouch_slide`/`crouch_idle`/`crouch_walk`/`uncrouch` | `PlayerStateSquat` (100%) | ✓ nerve mapping; nuances (D12) |
| `slope_slide` | `PlayerStateSlope` (100%) | ✓ end conditions; entry kick unmodeled (D9) |
| `ground_spin` | `PlayerStateGroundSpin` (100%) | ✓ |
| `knockback`/`knockback_land`/`dead` | `PlayerStateDamageLife` (100%) | ✓ + 120-step cap confirmed |
| `pit_fall`/`pit_recover` | `PlayerStateAbyss` (100%) | ✓ |

## Application status (2026-11-03, Joey: "put the fixes in")

**Applied** (engine + JSON + regression tests, 169/169 tests pass, ff clean):
- D1: dive `enter_horizontal_speed: 20.0` (new engine field; HeadSlidingSpeed
  from decomp PlayerConst default, consistent with community "Dive (in the
  air): 48" ≈ 2.4×20). Test: `dive_sets_entry_speed_d1`.
- D3: dive `accel_forward: 0.5 → 0.0`. Test: `dive_no_forward_accel_d3`.
- D5: jump_wall `input_invalidate_frames: 25` (new engine field;
  WallJumpInvalidateInputFrame from decomp default). No behavioral test —
  jump_wall has no stick accel, so the blackout is currently unobservable;
  kept as a faithful structural lock.
- D6: gp_stall `enter_keep_horizontal: true → false`. Test:
  `gp_stall_zeroes_horizontal_d6`.
- D8: wall_push entry/exit → 45° decomp judge via new `on_facing_wall`
  condition (facing 135-180° vs normal + stick 0-45° vs facing). The old
  10°-cone tests were rewritten; `wall_push_exits_when_wall_lost` was
  inverted to `wall_push_persists_when_wall_lost` — deliberate deviation:
  Godot's is_on_wall() flickers, so we do NOT exit on wall loss (avoids the
  run↔wall_push oscillation from the 2026-11-03 saga). Tests:
  `wall_push_pose`, `wall_push_exits_on_stick_change`,
  `wall_push_persists_when_wall_lost`.
- D9: slope_slide `enter_min_horizontal_speed: 5.0` (new engine field).
  Test: `slope_slide_entry_kick_d9`.
- D12: crouch_slide `enter_kill_backward: true` + `brake_end_speed: 3.5`
  (new engine fields; SquatBrakeEndSpeed from decomp default, matches the
  spec's existing CR-01 threshold). Test: `crouch_slide_brake_snap_d12`.
  Note: the per-tick decay was already correct (0.05 = 1 − 0.95 =
  SquatBrakeRate).

**Deferred / not applied:**
- D2 (dive upward pop): the decomp proves the pop exists (zero downward
  velocity, then `velV -= HeadSlidingJump * gravity`; independently confirmed
  "propel himself upward and forward" by GameFAQs controls). BUT the default
  HeadSlidingJump=28.0 computes to a non-physical +84 u/tick (would out-jump
  the triple jump; contradicts the dive-bounce's existence), so the shipped
  BYAML must override it. **Need the value from Joey's spec doc.**
- D4: verified consistent already (enter_impact_speed overwrites) — no change.
- D7 (gp_fall ramp vs slam): SKIPPED deliberately — conflicts with Joey's
  explicit 2026-11-03 feel call ("too slow", gravity 8.0 for a real slam).
  Note the decomp defaults (HipDropSpeed/Gravity/Max = 45/45/45) actually
  reach -45 within ~1 tick, so the shipped behavior is close to the slam
  anyway; the JSON's enter_vy=-45 + terminal 45 captures it.
- D10 (gp_land 10.0 weak threshold): our land model has no weak/strong
  variants — would need a new feature. Noted for later.
- D11 (knockback two flavors): our knockback sets no entry velocity in JSON
  (impulse comes from the game code), so the flavor logic lives outside the
  behavior file. Noted for later.

## Divergences (actionable)

**D1 — dive: entry horizontal is SET, not kept.** Decomp (`exeDive`, first step):
`setVelocity(HeadSlidingSpeed * velH + velV)` — horizontal is normalized and scaled to
`HeadSlidingSpeed` (facing if zero). Ours: `enter_keep_horizontal: true`. → set horizontal
to `HeadSlidingSpeed` on entry instead of keeping.

**D2 — dive: upward pop on entry.** Decomp zeroes downward velocity, then
`velV -= HeadSlidingJump * gravity` (gravity points down → this is an *upward* pop).
Ours: no `enter_vy`. → add the pop (value from spec/BYAML).

**D3 — dive: no forward accel.** Decomp calls `moveDivingJump(..., 0.0f /*accel*/, HeadSlidingBrake,
HeadSlidingSpeed, ...)` — forward accel is literally 0; only brake + side accel. Ours:
`accel_forward: 0.5`. → set 0.

**D4 — jump_wall entry: consistent (checked, no change).** Decomp does
`setVelocity(WallJumpHSpeed * front)` — a set, not a keep. Ours has both
`enter_keep_horizontal: true` AND `enter_impact_speed: 8.6`; the engine applies
impact_speed *after* (overwrites horizontal along the wall normal), so the net effect
already matches. The keep flag is redundant but harmless.

**D5 — jump_wall: input blackout missing.** Decomp passes `WallJumpInvalidateInputFrame`
to the air-move control — stick input is ignored for N frames after a wall jump. Ours
models no blackout. → add (frames from spec).

**D6 — gp_stall: full velocity zero.** Decomp (`exeStart`, first step):
`al::setVelocityZero(mActor)` — kills horizontal too. Ours: `enter_vy: 0` +
`enter_keep_horizontal: true`. → zero horizontal as well, unless kept as a deliberate
feel deviation (record it if so).

**D7 — gp_fall: ramp, don't slam.** Decomp: one `HipDropSpeed` kick on first step, then
per-tick `addVelocityToGravityLimit(HipDropGravity, HipDropSpeedMax)` — it ramps up to
max, never slams to max on entry. Ours: `enter_vy: -45` set + gravity 8.0 (Joey's feel
change). → deliberate deviation; keep only if the feel choice stands.

**D8 — wall_push: the real game uses 45° cones, not 10°.** Decomp judge requires ALL of:
on ground, wall contact, `front·(−wallNormal) ≥ cos(45°)`, stick moving,
`moveDirection·front ≥ cos(45°)` — note the stick is checked vs **facing**, not vs the
wall normal. Ours: stick 170–180° vs wall *normal* (10° cone). The actual game is far
more generous on both axes. Given the wall_push pain this week, aligning entry to 45°
cones (stick-vs-facing) matches the shipped game; the 10° cone is stricter than Nintendo.

**D9 — slope_slide: entry min-speed kick unmodeled.** Decomp `appear()`: if directed
speed along slide dir < **5.0** (hardcoded), boost to 5.0; clamp to `SlopeSlideMaxSpeed`.
Ours: empty steer. → adopt the 5.0 kick + max clamp at minimum.

**D10 — gp_land: weak-landing threshold is hardcoded 10.0.** Decomp compares
`|groundPos − landPos|·gravity ≤ 10.0f` for the weak landing reaction. Adoptable as-is.

**D11 — knockback: two flavors.** Decomp `appear()`: with pre-existing velocity → keep
horizontal, keep upward vy, air control under `GravityDamage`; plain hit →
`velocity = −PushPowerDamage * front`, `HopPowerDamage` up. Check the spec models both.

**D12 — crouch_slide: brake is speed-proportional + kills backward motion.** Decomp
`exeBrake`: `vel *= SquatAccelRate * hSpeed` (floored at `SquatBrakeEndSpeed` → 0), and on
entry any velocity opposing facing is removed outright (unless skate). Ours: fixed
`decay: 0.05`. Nuance-level; proportional brake matches the game.

## Confirmed consistent (no action)

- `jump_long`: inertia-rate entry setup + `moveDivingJump` constant list + ceiling reflects
  + kill on ground. Helper math unverifiable.
- Hip-drop nerve structure (Start→Fall→Land); dive allowed from Start/Fall
  (`isEnableHeadSliding`) — matches our `gp_stall`/`gp_fall → dive`; land-cancel windows
  (`JumpHipDropPermitBegin/EndFrame`, `HipDropLandCancelFrame`) match our jump-out-of-land.
- Wall dispatcher: slide→jump on pre-input jump; jump→slide when wall-keep holds; slide
  end records wall-leave. Matches our `wall_slide ⇄ jump_wall`.
- Crouch nerves Brake→Wait→Walk→StandUp map to our
  `crouch_slide`→`crouch_idle`→`crouch_walk`→`uncrouch`; long jump gated on Brake +
  forward motion (`isEnableLongJump`) matches spec.
- `ground_spin`: fixed `GroundSpinFrame` duration; per-tick `v *= BrakeRate`,
  `max(|v|, MoveSpeedMax)`, `v += AccelRate * input`, `vy = −GravityMove` — same shape as ours.
- Knockback 120-step Damage cap (hardcoded) — matches our SP-04; ceiling→crouch
  (`isFormSquat`) matches our SP-03.
- Pit fall/recovery, slope end conditions (slow + gentle + past `SlopeForceFrame`).

## Still unverifiable from the decomp

Regular jump (jump1/2/3…), roll, all cap states, swim, run/air-move core, wall-slide
per-tick physics, long-jump/dive helper arithmetic, all transition conditions, all
shipped numeric values.
