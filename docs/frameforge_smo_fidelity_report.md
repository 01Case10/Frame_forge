# SMO Controller — Fidelity Report

**Behavior:** `smo_movement.json` (SMOMovement)
**Date:** 2026-11-03 (post spec-audit; full audit at `hidden_files/smo_audit_report.md`)
**Spec:** `State_machines.md` (79 states, 187 transitions) + `SMO-Style_Character_Controller_for_Godot__Rust__Implementation_Plan.md` App. A/B

## Coverage

| Metric | Spec | Implemented | Notes |
|--------|------|-------------|-------|
| States | 79 | 75 (70 Nerves + 5 Cap) | 68 spec + 7 slice variants |
| In-scope states | 68 | 68 | 100% |
| Out-of-scope | 11 | 0 | See below |
| Transitions (rows) | 187 | 938 | Per-state expansions (GL alone is 389 rows) |
| Source tags | — | 938/938 | 0 missing |

**Out-of-scope states (11):** talk, fp_start, fp_wait, fp_end (cutscene/dialogue); cap_latched, cap_p2, capture_flyin, captured (capture, v1 out); auto_run, auto_dash (Gap G26); updraft (basis N).

**Slice-model additions (7, not in spec):** jump1_cut, jump2_cut, jump3_cut, jump_cap_return_cut (legitimate hold/release slices for variable-height jumps); jump_spin_drill (AR-06 drill-cancel entry — engine applies enter_vy unconditionally, so the spec's −35 u/fr revert needs its own entry); cap_bounce_dive (231u/16), cap_bounce_pound (390.5u/14) (CP-02 variants — enter_vy is per-state). Removed 2026-11-03: jump_long_cut, jump_back_cut, jump_side_cut, jump_spin_cut (contradicted the spec's fixed heights 144/496/496/490).

## Conventions (C1–C4)

- **C1:** Same-tick transition semantics (FrameForge fires during row eval; new state's delta applies same tick). Doc's next-tick model (Gap G28) resolved by convention.
- **C2:** Implemented — GR-06 (pri 39) before GR-05 + unconsumed 5-tick buffer; jump pressed with run start fires on tick 2 in run.
- **C3:** Crouch pressed same tick as run start delayed 1 frame. Implemented via row ordering (GR-06 pri 39 before GR-03 pri 30).
- **C4:** Cap throw overrides run immediately (GR-02 pri 20). Implemented.

## What the 2026-11-03 audit fixed (10 MUST-FIXes)

1. **RL-08:** roll/roll_standup → fall on ground loss (pri 12). Rolling off a ledge was a dead end. (The spec's 2-tick −7 u/fr grace is approximated as immediate.)
2. **RL-02:** first-boost timing 16 (crouch entries) vs 32 (pound/spinpound entries) via `roll.entry`; shake added to boost inputs. The 23/26/29 tier floors are not expressible in the steer model (no event-driven speed set); permanent `speed_min` 20 covers the failed-boost floor.
3. **gp_fall:** terminal 60 → 45 u/fr (spec); entry vy −45 (S-019 "reaches terminal at once"). Gravity 8.0 kept (spec-silent, feel tuning).
4. **Cap-bounce:** new `bounce_ability` flag (set on land/ledge/pole/vault, cleared on wall jump/bounce); CP-02 restricted to hover (spec "Extended"); dive/pound variants as `cap_bounce_dive`/`cap_bounce_pound` with W-num heights and speed caps; missing CP-02 rows on dive/gp_stall/gp_fall added.
5. **AR-06:** spindrill cancel → `jump_spin_drill` (vy −35, spec) instead of re-arming jump_spin's +39.1. Spindrill also loses horizontal on entry (spec).
6. **GR-04:** spin (pri 35) now sorts after crouch (pri 30) — was inverted.
7. **JP-03/JP-04:** moving crouch_slide (hspeed≥1) → long jump; stationary slide / braking coyote → backflip ("moving or not decides"). New `coyote.origin` tracks the pre-coyote ground state (spec `origin` flag). The 9-tick slide-coyote bound is not enforced.
8. **Throw kinds:** `throw.kind` (standard/up/down) + `cap.air_throw`; all 30 throw entries set them; CP-06/07/08/09/10/11/16/17 timing tables are kind-conditional per the W-num tables (up/down air values not printed → ground values, Gap). Kind selection via `cap_throw_up`/`cap_throw_down` inputs (driver-wireable; playground maps standard only).
9. **slope_slide:** SP-16/17/18/19 exits added (fall / jump / run / idle); SP-20 entry guard restored (crouch&steep or forced_slide, pri 15); SP-21 sand death, SP-22 leave-sand→idle.
10. **GL coverage:** GL-01/02/04/05/06/07 on all 69 live Nerves states (389 rows), ahead of every other row. PLAYGROUND-FIX rows re-sorted below them.

## Slice-Model Assumptions (remaining)

**Timings (not printed):** ledge_climb 10; gp_stall 12; gp_land 30; bonk 30; land_hard 60; cap_return_spin 20; knockback_land 60; dead 120; pit_fall 60; pit_recover 30; sand_sink death 120; cap homing 10; cap return 20.

**Physics (not printed or Gap):** run accel 1.0; pivot flat 20°/tick (doc: 2-tick wait + 0.1×step×angle — not expressible in TurnModel); wall_slide gravity 0.5/terminal 4.0; pole_slide gravity 0.8/terminal 8.0; ground_spin 0.95v+0.5r cap 8 (engine order gives 0.95v+0.475r); jump gravity 1.5 (v0 tuned to doc heights; all fixed heights verified exact under decrement-then-integrate); RL-08 grace approximated; dive/pound bounce frame counts not modeled (heights exact).

**Guards (simplified):** GR-17 15° assumed; CR-04/CR-05 headroom via new `ceiling.low` probe (defaults false = no ceilings); JP-08/10 triple/double are opaque engine predicates (`smo.triple_ok`, `smo.double_ok`); AR-27 15° assumed; "forward speed" proxied by `motion.hspeed`; contact tests A/B collapsed to bridge bool `cap.touch`; shake inputs declared but unfed by the playground driver; 2D-section guards absent everywhere.

**2026-11-03 wall-slide fix:** `resp_wall -> wall_slide` was missing on all cut states (`jump1/2/3_cut`) and jump variants (`long/back/side/spin/spin_drill/cap_return`), so releasing jump early then hitting a wall never slid (Joey's "wall jump works half the time" — the failures were all `jump1 -> jump1_cut -> land_sel` at the wall). Added to 16 airborne states per spec G-air-all (every airborne state); `dive` keeps `bonk` (spec: "Not for a roll or a dive").

## Bridge-Fed Probes (43 params)

The embedder (Godot) must provide these per tick (new since 2026-10-19 marked ★):

**Contact:** `contact.ground`, `contact.wall`, `ground.dist` (float, -1=none)
**Motion:** `motion.hspeed`, `fall.distance`
**Water:** `water.surface`, `water.depth`
**Hang:** `ledge.available`, `pole.available`, `ceiling.available`, `pole.top`
**Stick:** `stick.up`, `stick.down`
**Damage:** `damage.event`, `damage.ground`, `life.zero`, `held.object`
**Pit:** `pit.below`, `pit.safe`
**Surface:** `surface.steep`, `surface.sand`, `surface.forced_roll` ★, `surface.forced_slide` ★
**Bounce:** `bounce.contact`, `bounce.height` (declared; variant heights now live in states)
**Cap:** `cap.state`, `cap.touch`
**Ceiling:** `ceiling.low` ★ (true when headroom too low to stand)
**Throw:** `cap_throw_up`, `cap_throw_down` ★ (input actions; optional)

**Engine-managed (do not set):** `chain.state`, `chain.ground_window`, `air.from`, `jump.pound_ok`, `quickturn.latch`, `cap.catch_window`, `cap.spin_used`, `spin.valid`, `jump.origin`, `coyote.origin` ★, `roll.entry` ★, `throw.kind` ★, `cap.air_throw` ★, `bounce_ability` ★, `always`

## Known Issues (remaining)

1. **RL-02 tier floors:** 23/26/29 boost floors not expressible (steer has no event-driven speed set). Timer + shake modeled.
2. **AR-02 trigger:** `bounce.contact` fed by nothing live (only tests); state graph correct.
3. **JP-09 chain:** failed triple → jump1 no longer re-arms (chain.state=1 moved to JP-11's on_fire), but the 9-tick window still re-arms on landing — "cannot start a new chain" is partially enforced.
4. **contact.ground:** embedder-fed probe; no auto-detection.
5. **input_lock:** wall jump's 25-frame input lock not modeled (engine has no input-lock mechanism; Countdown assign would be a no-op).
6. **Pivot schedule:** flat 20°/tick vs spec's 2-tick wait + 0.1×step×angle (not expressible in TurnModel).

## Test Status

- 55/55 anchor tests green (`smo_p0.rs`; includes new cap_bounce_dive 231u, CR-08, drill-cancel −35 checks)
- 159/159 full Rust suite green; zero clippy warnings; `ff check` clean
- Godot `playground_anim_test`: 84/84 states mapped, 0 failures (integration skipped — BehaviorPlayer not built on this VM)

## Playground overrides (user decisions, not spec)

- **Wall_push redesign (2026-11-03):** only in wall_push while pressing into the wall; release → idle, pull back → run. (Spec GR-20/21 superseded.)
- **Direct roll (Gap G17):** crouch pressed at hspeed≥7 while running → roll. (Spec leaves the direct-roll flag consumer open.)
- **Ground-pound feel:** gp_fall gravity 8.0 (spec-silent), gp_stall hover steer.
- **Stick X negated** (core frame mirrored vs Godot camera); **B = roll** mapping.
