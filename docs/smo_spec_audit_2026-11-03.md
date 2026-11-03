# SMO Movement JSON — Spec-Compliance Audit Report

**Date:** 2026-11-03
**Target:** `~/workspace/frameforge/rust/behaviors/smo_movement.json` (314 KB, modified 2026-11-03)
**Spec:** `~/workspace/user/files/State_machines.md` (79 states, 187 transitions, IDs GL/GR/CR/RL/JP/AR/WL/WT/CP/SP)
**Constants:** `SMO-Style_Character_Controller_for_Godot__Rust__Implementation_Plan.md`, Appendix A (seed constants) + B (gap register)
**Fidelity report (claims checked):** `~/workspace/frameforge/docs/frameforge_smo_fidelity_report.md` (dated 2026-10-19 — partly stale, see §13)
**Driver (consulted where needed):** `~/workspace/frameforge/playground.gd`, `rust/frameforge-godot` bridge, `rust/frameforge-core/src/tick.rs`
**Mode:** read-only audit. No files modified.

## Method

Eight parallel workers audited one spec section each, verifying guard values, tick counts, and thresholds **inside** each transition's `condition` (not just `source_tag`), and checking that each state's transition list order respects spec priority (JSON: first match wins; spec: lowest priority number wins). The coordinator independently verified engine semantics in `tick.rs` and corrected three worker errors (see §14).

**Engine semantics (verified in `tick.rs`):**
- `state_step` reads the 0-based track frame; `state_step >= N` yields **exactly N ticks** of the state (the `just_entered` mechanism skips one frame advance so frame 0 is observed exactly once, compensating the same-tick delta).
- Physics is decrement-then-integrate (`vy -= g; y += vy`), so jump peak height = `v²/2g − v/2`, not `v²/2g`.
- Buffered presses persist unconsumed across a state change (matters for C2).
- Transitions fire during row eval; the new state's delta applies the same tick (fidelity report C1).

**Severity key:** MUST-FIX = contradicts a sourced spec rule/number (W-num/D-num/D-rule/W-rule). SHOULD-FIX = simplified guard the spec defines precisely, or an incomplete implementation. CONVENTION = spec Gap or stated ambiguity — the JSON's choice is a convention, recorded not blamed. STALE-DOC = fidelity-report claim no longer true. SCOPE = documented out-of-scope decision (the 11 states), not a bug.

## §1 — Summary tables

### States: 79 spec vs 76 JSON

| | Count | Detail |
|---|---|---|
| Spec states | 79 | per State_machines.md |
| JSON states | 76 | 71 Nerves + 5 Cap |
| In-scope spec states present | 68 | 63 Nerves + 5 Cap — verified by token scan |
| Cut-variant additions | 8 | jump1_cut, jump2_cut, jump3_cut, jump_long_cut, jump_back_cut, jump_side_cut, jump_spin_cut, jump_cap_return_cut — the only non-spec states |
| Out-of-scope, absent as claimed | 11 | talk, fp_start, fp_wait, fp_end, cap_latched, cap_p2, capture_flyin, captured, auto_run, auto_dash, updraft — all confirmed absent |
| Other spec states missing | 0 | — |

The fidelity report's "68 + 8 cut, 11 out-of-scope" claim is **verified exact**.

### Transitions by section (spec rows audited)

| Section | Spec rows | Correct | Wrong | Missing | Opaque/Conv. | Undoc. additions |
|---|---|---|---|---|---|---|
| GL global interrupts | 10 | 6 (partial¹) | 0 | 1 (GL-08²) | 3 (GL-03,09,10 scope) | 0 |
| GR ground | 28 | 9 | 6 | 1 (+partial gaps) | 8 (scope/redesign) | 8 |
| CR/RL crouch/roll | 19 | 7 | 9 | 3 | 0 | 2 (admitted slice) |
| JP jump selector | 11 | 5 | 4 | 0 | 2 (opaque predicates) | 10 (tagged slice/PLAYGROUND) |
| AR air/pound/land | 23 | 18 | 5 | 4 instances | 5 conventions | 2 |
| WL walls/ledges/poles | 22 | 15 | 5 | 1 | 6 (G35 etc.) | 3 (G42) |
| WT water | 15 | 7 | 0 | 0 | 8 (G35/G57) | 0 |
| CP cap throws/machine | 25 | 12 | 6 | 1 | 6 (out-of-scope) | 0 |
| SP special | 20 | 9 | 5 | 6 | 0 | 0 |
| **Total** | **173** | **88** | **40** | **16** | **38** | **25** |

¹ GL-01/02/04/05/06/07 present on 3/71 states only (idle, run, fall) — spec requires ~50–60.
² GL-08 exists only as simplified pri-48 slice rows, not the spec's pri-8 row.
JSON has 423 total transitions (fidelity report's "418/418 tagged" is now 423/423 — the 5 new ones are PLAYGROUND-FIX rows, all tagged).

Steering rules (9): 3 wrong, 1 missing body, 4 partial. Technique paths: T02, T06, T16 broken; T15 N/A; rest OK. Parameters (35): 2 issues (1 dead, 1 write-only).

## §2 — Global interrupts (GL)

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| GL-01/02/04/05/06/07 | MUST-FIX | only idle[0-5], run[1-6], fall[0-5]; absent on other ~68 states | From L12 (GL-01) / G-hurt (rest): every live state, fixed order 1,2,4,5,6,7 | damage/death/pit interrupts missing on brake_stop, brake_turn, pivot, pivot_moving, wall_push, ground_spin, all air/crouch/roll/water/special states | add the rows per spec From-groups (fidelity Known Issue #3 already documents this gap — still accurate) |
| GL-01 | SHOULD-FIX | idle.0, run.1, fall.0 | `dead_guard` = "life is zero, or the actor is dead" | checks `life.zero` only | add "or actor dead" disjunct |
| GL-08 | SHOULD-FIX | idle/run/crouch_slide pri-48 slice rows | G-gnd-sand → sand_sink, pri 8, settle-counter > 15 guard | simplified `surface.sand` rows at pri 48, no counter | restore pri 8 + settle-counter guard (or keep slice, document) |
| GL-03 | CONVENTION | — | capture interrupt | absent — capture out of scope | none |
| GL-09/10 | CONVENTION | — | → auto_run / auto_dash, pri 9a/9b | absent — targets out of scope (Gap G26, not player-controlled) | none |

In-list order on the three covered states is ascending (1,2,4,5,6,7) ✓.

## §3 — Ground movement (GR)

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| GR-04 | MUST-FIX | run.11, brake_stop.4, brake_turn.4, pivot.4, pivot_moving.4 | pri 35, listed **after** GR-03 (pri 30): crouch beats spin | tagged pri 21 and listed **before** GR-03 → spin_valid beats crouch_held | move GR-04 after GR-03; correct tag to pri 35 |
| GR-01 | MUST-FIX | ground_spin (absent) | From G-coy: run off edge → coyote | no row | add GR-01 to ground_spin (wall_push covered by redesign, see below) |
| GR-23 | MUST-FIX | ground_spin (absent) | step 90 + stick_moved → run, pri 45 | absent | add row before GR-24 |
| GR-24 | MUST-FIX | ground_spin.3 (tag GR-04-DONE) | spin ends step 90 (91 ticks) **+ stick_neutral** → idle | `step>=91` unconditional (timing = 91 ticks ✓ correct) | add stick_neutral guard; add GR-23 |
| GR-05 | SHOULD-FIX | water_run (absent); wall_push has unbuffered PLAYGROUND jump | From G-jumpable, 5-tick buffer → jump_select | water_run has no buffered jump row | add buffered GR-05 to water_run |
| GR-02 | SHOULD-FIX | idle.9, run.10, brake_stop.3, brake_turn.3, pivot.3, pivot_moving.3 | cap_press **or shake**; throw needs **cap_held** | `cap` any_pressed only, no cap_held conjunct; shake input doesn't exist anywhere in JSON | add `cap.state==held` conjunct (air rows already have it); shake needs a driver probe |
| GR-03 | SHOULD-FIX | idle.10, run.12, brake_stop.5, brake_turn.5, pivot.5, pivot_moving.6 | crouch starts **one tick after the press**; nothing carried; not on forced run | any_held fires on press tick; no carried/forced_run checks | delay 1 tick; add conjuncts |
| GR-10/11 | SHOULD-FIX | idle.16, run.14 | wall_push needs wall⊥ground, facing **and** stick within 45° of wall normal | wall&&ground + stick 0–90° vs facing; no wall-normal checks | add facing-vs-wall-normal ≤45° and stick-vs-wall-normal ≤45° |
| GR-22 | SHOULD-FIX | ground_spin.1 | pri 34, guard incl. "tries to run" | tagged pri 20, guard spin.valid only (relative order unaffected) | fix tag to 34; add stick_moved conjunct |
| GR-06/07 | SHOULD-FIX | idle.11, idle.13 | stick_back = angle ≥95° → pivot wins at exactly 95° | both ranges include 95.0; GR-06 listed first wins ties | make GR-06 angle_max exclusive of 95 |
| pivot steer | SHOULD-FIX | pivot state | W-num Pivot: 2-tick wait, ω = 0.1×step×angle, done by tick 10 | flat 20°/tick cap, no wait, no schedule | model the schedule |
| ground_spin steer | SHOULD-FIX | ground_spin state | W-num Spinning: speed cap 8 u/fr | no steer block at all | add steer with speed_cap 8 |
| GR-08/09/19/25-28 | SCOPE | n/a | talk / fp_* rows | states absent — cutscene/dialogue out of scope per fidelity report | none (documented scope) |
| GR-20/21 | CONVENTION | wall_push.0/1/2 | wall_push→run / →idle, pri 45/46 | replaced by PLAYGROUND-FIX rows per Joey's 2026-11-03 wall_push redesign (standing user override) | none; record override |
| GR-17 | CONVENTION | pivot_moving.8 | "velocity has shifted to the stick direction" (no number; Gap) | assumes 15° vs velocity, tag documents it | keep |
| GR-02/03 (wall_push) | CONVENTION | wall_push | From G-flat / L1 | absent — covered by redesign override | none |

**Undocumented additions (8):** run.0 `PLAYGROUND-FIX: B while running → roll`; wall_push.0/1/2 PLAYGROUND-FIX exits (redesign); idle.14/run.17 SAND→sand_sink pri 48 (slice); idle.15/run.18 SLOPE→slope_slide pri 48 (slice); ground_spin.3 GR-04-DONE→idle (slice). **Cross-cutting:** PLAYGROUND-FIX rows carry no pri tags and sort **before** GL rows — e.g. run.0 (→roll) is evaluated before run.1 (life.zero→dead). SHOULD-FIX: give them explicit priorities below GL-01.

**State fields OK:** run cap 3.0+11.0×r ✓ (11r+3); turn tiers 6.5–8.5° ✓; brake decel 1.4 ✓; brake_turn quickturn.latch 20 ✓; ground_spin duration 91 ✓.

**Struck by coordinator (§14.3):** GR-14/15/16b/24 timing MUST-FIXes — JSON `ge 11/13/10` = 11/13/10 ticks ✓ matches spec ("brake lasts 11 ticks", "opposite way after 13 ticks", "at most 10 frames").

**Conventions C2/C3/C4:** C2 (jump delayed 1 tick when pressed with run start) is **implemented** — GR-06 (pri 39) before GR-05 (buffer 4); the press stays buffered and GR-05 fires next tick in run. STALE-DOC: fidelity report Known Issue #1 + Next Step #2 say C2 is not implemented. C3 ✓ (GR-03 pri 30 before GR-06). C4 ✓ (GR-02 pri 20 before GR-06).

## §4 — Crouch and roll (CR/RL)

19 rows: 7 correct / 9 wrong / 3 missing. All 6 states ascending priority ✓. Engine note (verified in tick.rs): `ge N` fires after exactly N ticks; RL-02's self-loop resets `frame`, so post-boost cooldowns correctly measure from the last boost.

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| CR-05 | MUST-FIX | uncrouch (absent) | uncrouch→crouch_slide when stand-up guard turns false (low ceiling), pri 29 | absent; uncrouch[3]→crouch_slide is GR-03 (re-press), a different row | add CR-05: ceiling/headroom-false → crouch_slide, pri 29 (ahead of CR-06/07). Note: unreachable while CR-04 assumes guard true — if ceilings stay out of the slice, record the pair as accepted convention |
| RL-01 | MUST-FIX | all L2 states (absent) | L2→roll on forced-roll surface, pri 19, nothing carried | zero hits across all 71 states | add forced-roll rows to all L2 states, pri 19 |
| RL-02 | MUST-FIX | roll.2 | boost floors white 23 / small yellow 26 / large yellow 29 (shake only); failed boost → ≥20 u/fr; shake never fails | bare self-loop "boost amount not printed; resets timer" — no speed change, no floors, no failure logic, shake absent (playground.gd has zero boost code) | implement boost speed floors + failed-boost 20 floor + shake input |
| RL-02 | MUST-FIX | roll.2 | first boost after 16 frames (crouch roll) or **32** (pound/spinpound roll); 17/15 variants | flat `state_step>=16` for all entries — pound-roll entries (gp_land→roll via AR-13) boost at 16 instead of 32 | gate first-boost timing by entry variant (needs entry-origin flag); 32 for pound/spinpound entries |
| RL-08 | MUST-FIX | roll, roll_standup (absent) | roll/roll_standup→fall when no standable ground for >2 ticks, pri 12 (−7 u/fr hold 1–2 ticks) | neither state has any ground-loss transition — rolling off a ledge is a dead end | add RL-08 rows (pri 12) to both; model the −7 u/fr 1–2 tick hold |
| CR-04 | SHOULD-FIX | crouch_idle.5, crouch_walk.5, crouch_slide.5 | crouch released AND stand-up guard true (headroom) | `none_held(crouch)` only; tag admits "stand-up guard assumed true (no ceilings in slice)" | add headroom check (or keep slice assumption — then CR-05 is dead code; decide one) |
| CR-08 | SHOULD-FIX | crouch_idle.3, crouch_walk.3, crouch_slide.3 | `cap_press` **or `shake`** (throw from crouch) | `any_pressed(cap)` only | add "shake" to input_actions |
| CR-09 | SHOULD-FIX | uncrouch.2 | `cap_press` or `shake` | `any_pressed(cap)` only | add "shake" |
| RL-03 | SHOULD-FIX | roll.6 | stand up after wait 33 (pound roll) / 47 (crouch roll) / 46 (after a boost) | `state_step>=33` only; tag admits "47 crouch / 46 boost not modeled" | select threshold by roll variant |
| RL-04 | SHOULD-FIX | roll.7 | flat ground AND forward speed < 17 u/fr → roll_standup | `motion.hspeed < 17` only — no flat-ground check, and hspeed ≠ forward speed | add `surface.steep == false` |
| RL-05 | SHOULD-FIX | roll.3 | `cap_press` or `shake` (roll cancel), ≥9 ticks after boost | `any_pressed(cap)` only; timing correct (self-loop resets) | add "shake" |
| RL-06 | SHOULD-FIX | roll resp_wall field | roll→bonk on wall hit **head-on (within 55°)**, pri 22 | resp_wall→bonk with min_incoming_speed 0.0 — fires on ANY wall touch, no angle guard; evaluation order vs pri-21/23 transitions is engine-defined | add 55° head-on angle guard |
| CR-02 | SHOULD-FIX | crouch_idle.6 | `stick_moved` + start_run (no facing restriction) | adds stick_angle_max 95° cone — backward stick (95–180°) won't start crouch_walk, spec would allow | drop the angle restriction or source it |
| uncrouch gravity | SHOULD-FIX | uncrouch state | A1: uncrouch gravity 3 u/fr² | no steer block / no gravity field | add gravity 3 u/fr² |

**Verified OK:** roll decay 0.002 ✓, cap 35 ✓, min 20 ✓, turn 5°/fr ✓; roll_standup duration 10 ✓ with no jump/cap-throw/turn rows ✓; crouch_walk cap 3.5 ✓ turn cap 30 ✓; crouch_slide decay 0.05 ✓ accel_side 0.25 ✓ gravity 1.5 ✓; uncrouch duration 14 ✓; RL-02 (pri 20) correctly precedes RL-05 (pri 21).
**Conventions (not bugs):** crouch_slide sideways −7%/fr and sideways-cap-half not modeled (one decay slot); crouch_walk turn accel 3°/fr² not encoded (no schema field); roll sideways drift 0.4 (0.6 ice), downhill accel, ice variants not modeled; RL-02 17/15-frame cooldown variants not modeled (Gap-adjacent).
**Undocumented:** crouch_slide[7]→sand_sink, [8]→slope_slide — tagged "SAND/SLOPE [pri 48] [Slice: simplified (doc has no ID)]", self-admitted; fidelity report already lists SAND/SLOPE as slice rows.

## §5 — Jump selector (JP)

11 rows: 5 correct / 4 wrong / 2 opaque. jump_select list order pri 1→11 ascending ✓. Jump physics spot-check (decrement-then-integrate, peak = v²/2g − v/2): jump1 31.35→312.3 ✓, jump2 33.0→346.5 ✓, jump3 41.37→549.7 ✓, jump_long 21.54→143.9 ✓, jump_back/side 39.33→495.9 ✓, jump_spin 39.1→490.1 ✓ — all match spec heights exactly.

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| JP-03 | MUST-FIX | jump_select.2 | origin crouch_slide AND **forward velocity > 0** (3D, alive); coyote-from-slide ≤ 9 ticks → long jump | only `jump.origin == "crouch_slide"` | add forward-speed>0 guard + coyote tick bound; as-is it swallows JP-04's stationary-slide branch |
| JP-04 | MUST-FIX | jump_select.3 | other crouch origins **incl. crouch slide with NO forward speed**, or braking coyote → backflip | any_of(crouch_idle, crouch_walk, uncrouch) only | add crouch_slide-no-speed alternative (paired with JP-03: "moving or not decides") and braking-coyote alternative |
| JP-05 | SHOULD-FIX | jump_select.4 | origin ground_spin / spin coyote / **buffered spin_valid while moving on ground** | any_of(origin==ground_spin, spin.valid) — no moving-on-ground gate on the buffered variant | gate spin.valid branch on moving-on-ground |
| JP-07 | SHOULD-FIX | jump_select.6 | quickturn_active / within 20 ticks of last quickturn tick / **origin brake with stick_back** | `quickturn.latch > 0` only | add brake-origin + stick_back alternative |
| JP-09 | SHOULD-FIX | jump_select.8 | third press, triple failed → plain jump1, "cannot start a new chain" | `chain.state == 2` → jump1; jump1 enter sets chain.state=1, identical to a fresh single jump — would re-arm double_ok | engine must exempt a JP-09 jump1 from chain re-arming, or clear chain on third jump per flag spec ("cleared on a third jump"); smo.double_ok is opaque so this can't be confirmed from JSON |
| JP-08 | CONVENTION | jump_select.7 | triple chain intact (9 documented conditions) | on_custom `smo.triple_ok` → jump3 | opaque engine predicate — unverifiable by inspection |
| JP-10 | CONVENTION | jump_select.9 | previous single jump landed ≤9 ticks ago | on_custom `smo.double_ok` → jump2 | opaque engine predicate — unverifiable by inspection |
| AR-06 | MUST-FIX | spindrill.5 | "reverts to a spin jump with **downward speed 35 u/fr**" | →jump_spin, whose steer enter_vy `set: 39.1` (upward) re-arms on entry | cancel must not apply enter_vy; needs engine exemption or dedicated cancel entry |
| spindrill field | SHOULD-FIX | spindrill state | "Horizontal speed lost on the first frame" | steer `enter_keep_horizontal: true` | set false / add horizontal-loss on entry |

**Correct:** JP-01 (cap_return_window → jump_cap_return; engine-managed flag, semantics unverifiable), JP-02 (origin roll → jump_long), JP-06 (pound window → jump_gp), JP-11 (fallback → jump1). spindrill: −36.5 down, +1.5/fr to 45, cancel blocked first 6 frames ✓.

### Cut-variant verdicts

| Cut state | Verdict | Detail |
|---|---|---|
| jump1_cut, jump2_cut, jump3_cut | LEGITIMATE slice | variable height by release; entered via `jump` none_held; cut steer gravity 1.5→4.0, vy preserved, no re-press return (release-is-final matches SMO). SHOULD-FIX: each drops 9 common rows the parent carries (WT-01/02, AR-02 bounce, WL-04/05/06, AR-03 cap throw, CP-02 bounce, CP-03 return spin) — releasing the button shouldn't remove cap/ledge options. PLAYGROUND-FIX gp_stall rows at index 0 are ad-hoc (no spec ID), listed before AR-01 (pri 21 before 14) |
| jump_long_cut | CONTRADICTS spec — SHOULD-FIX | long jump is "144 u, fixed"; the cut reduces height on release. Remove or make cut a no-op |
| jump_back_cut | CONTRADICTS spec — SHOULD-FIX | backflip "496 u, fixed" + no midair facing control; cut adds gravity 4.0 AND full vectoring steering the parent lacks |
| jump_side_cut | CONTRADICTS spec — SHOULD-FIX | sideflip "496 u, fixed" |
| jump_spin_cut | CONTRADICTS spec — SHOULD-FIX | spin jump "490 u, fixed" |

**Undocumented:** 10 tagged-but-not-spec (7× SLICE-CUT, 3× PLAYGROUND-FIX); 0 untagged.
**STALE-DOC:** fidelity report "JP-08 (triple): omits 'moving on last tick', cap/sideflip clauses" — JP-08 is now the opaque `smo.triple_ok` predicate; the claim is neither verifiable nor refutable by inspection. Reword or drop.
**Boundary notes (for AR/CP workers' sections, confirmed):** dive lacks AR-19 (→fall dive-cancel), AR-20 (→cap_throw_air), AR-21 (→bonk); jump_long lacks AR-22 (→bonk head-on wall); jump_back/jump_side lack AR-04 (→gp_stall) despite L5 membership; dive/spindrill carry ledge/ceiling/pole grabs but aren't in L6.

## §6 — Air, pounds, landing (AR)

23 rows: 18 correct / 5 wrong / 4 missing instances. All 14 states ascending priority ✓. land_sel is a proper 1-tick decision node (8 rows, pri 1–8, duration_frames=1) ✓.

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| — | MUST-FIX | gp_fall steer | gp_fall terminal **45** u/fr (AR state table + A1) | `terminal_velocity: 60.0`, `gravity: 8.0`; engine clamps via tick.rs so this is live | terminal_velocity → 45.0 |
| CP-02/bounce | MUST-FIX | cap_bounce (no variant data) | dive 231u/21fr cap16, regular 300u/24fr cap24, pound 390.5u/22fr cap14, 2P 325u/25fr cap24 (A3 W-num) | no height/cap numbers anywhere; `bounce.height` declared (default 300.0) but never consumed; `bounce.contact`/`bounce.height` fed by nothing live (bridge lib.rs and playground.gd never set them — only tests do; fidelity Known Issue #2 still open) | implement bounce-variant selection feeding bounce.height + enforce speed caps; wire a live feeder for bounce.contact |
| AR-04 | MUST-FIX | cap_bounce, cap_return_spin, bounce_entity (absent) | L5 (air states that can start a ground pound) explicitly lists all three | no AR-04 →gp_stall row in any (9/10/5 transitions respectively) | add AR-04 pri 21 (crouch_press + ground.dist≥40 or <0) to all three |
| AR-03 | SHOULD-FIX | bounce_entity (absent) | L4 includes bounce_entity → cap_throw_air on cap_press/shake + cap_held | no AR-03 row | add AR-03 pri 20 |
| CP-02 | SHOULD-FIX | gp_stall, gp_fall, bounce_entity (absent) | L10 (air states that can bounce on the cap) lists all three | no CP-02 →cap_bounce row | add CP-02 rows |
| AR-23 | SHOULD-FIX | land_sel.0 | gp_land if "origin is Pound fall, **OR Spindrill with crouch_held until landing**" | guard only `air.from == "gp_fall"`; spindrill sets air.from="spindrill" but no branch | add `or (air.from=="spindrill" and crouch_held)` |
| WT-01/02 | SHOULD-FIX | bonk, bounce_entity | L7 includes both | bonk has 1 transition; bounce_entity lacks water rows | add WT rows |
| return_spin_used | SHOULD-FIX | ledge_hang, wall_slide entries | flag "cleared by ground contact, **ledge grab or wall slide**" | cleared on land_sel enter ✓, set on cap_return_spin enter ✓, but ledge_hang/wall_slide enter_params empty → flag leaks across a ledge/wall touch | clear cap.spin_used on those entries |
| AR-03/04/12 | CONVENTION | slice-wide | `cap_press` **or `shake`**; "not in a 2D section"; AR-12 downthrow "too soon" clause | cap any_pressed only, no shake; no 2D guard anywhere; AR-12 tag admits "simplified (no 'too soon' check)" | record slice calls (shake needs driver probe) |
| AR-08 | CONVENTION | coyote.4 | crouch extends coyote by 5 ticks (Gap G30: 9 or 10 total) | self-loop on crouch_press resets state_step → +6 ticks per press, repeatable indefinitely | slice mechanism; tag notes crouch_slide out of slice |
| AR-04/vault | CONVENTION | vault (absent) | "whether a wall jump or vault allows [pound] is Gap G42" | no AR-04 from vault | none until G42 resolved |
| AR-02 | CONVENTION | bounce_entity.0 | AR-02 From=L3 (excludes bounce_entity) | self-loop bounce_entity→bounce_entity tagged "AR-02 [D-rule: bounce again]" | needs a spec row (spec-gap candidate); plausible but undocumented |
| AR-26 | CONVENTION | land_sel.3 | "Not while dead, in a 2D section, held or captured" | bare fall.distance>=3000, no exceptions (ties to GL partial coverage) | cross-ref GL coverage |

**Verified correct:** coyote enter_vy −7.0 ✓, AR-09 step>=6 ✓, GR-05 (pri 40) < AR-09 (pri 45) so jump allowed on any of the 6 ✓, ground-like turn tiers ✓; fall/jump_gp/cap_bounce/vault/bounce_entity steer gravity 1.5, terminal 35.0, vectoring 0.5/0.3/1.0 + backward-until-zero ✓; midair facing 7.5×radius ∈ [1.5,6], deadzone 1° ✓; quickturn 135°/25°/fr ✓; gp_stall enter_vy 0, gravity 0, velocity zero ✓, duration 12 ✓; gp_land AR-12/13/14/15/16 ✓; CP-01 →vault ✓; cap_return_spin sets cap.spin_used=1, CP-03 guards ==0, land_sel clears ✓, CP-04 step>=20 ✓; bonk/land_hard AR-18/17, durations 30/60 ✓; ground_spin duration 91 ✓, GR-22 re-spin ✓; AR-28 buffer 4 = 5-tick window ✓; AR-29 stick-vs-velocity ≤95° ✓; AR-30 fallback ✓; AR-01 "touching standable ground" = contact.ground==true, slope condition lives in the feeder (bridge lib.rs) — JSON correct, driver-fed.
**Undocumented:** bounce_entity AR-02 self-loop; ground_spin.3 GR-04-DONE (slice).
**Struck by coordinator (§14.1):** the "step>=N fires after N+1 ticks" durations finding and its STALE-DOC — JSON guards give exactly the documented durations (12/30/30/60/20).

## §7 — Walls, ledges, ceilings, poles (WL)

22 rows: 15 correct / 5 wrong / 1 convention / 1 missing. All 9 states ascending priority ✓. All discrepancies below are JSON-side (playground.gd carries no WL probes; the Rust core consumes them).

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| WL-01 | SHOULD-FIX | ledge_hang.T0 | stick_forward: radius>0.1, ≤95° from facing, or jump_press | jump_press ✓; stick guard = radius≥0.5, angle 0–45° | widen to radius 0.1, angle ≤95° |
| WL-02 | SHOULD-FIX | ledge_hang.T1 | crouch_press or stick_back (angle ≥95°) | crouch ✓; stick guard = radius≥0.5, angle 135–180° | relax to ≥95°, radius 0.1 |
| WL-22 | SHOULD-FIX | pole_top.T1 | →fall on stick_forward (radius>0.1, ≤95°), pri 45 | on_stick radius≥0.5, angle 0–180° (ANY direction incl. backward), pri 45 | angle_max → 95°, radius_min → 0.1 |
| WL-08 | SHOULD-FIX | wall_slide.T5 | →jump_wall on jump_press (≤5 ticks), **not on forced-slide ground**, pri 25 | buffer_ticks 4 (= 5 ticks incl. press ✓), pri 25, but no forced-slide refusal | add refusal guard; no forced_slide probe exists in JSON yet |
| WL-08-field | SHOULD-FIX | jump_wall state | wall jump 8.6 u/fr, power 23, gravity 0.95, **input locked 25 frames** | enter_impact_speed 8.6 ✓, enter_vy 23.0 ✓, gravity 0.95 ✓; **no input_lock set** (enter_params empty; engine supports Countdown assigns but unused; 0 "lock" occurrences in JSON) | add enter_param Countdown input_lock=25 |
| WL-07/S-032 | SHOULD-FIX | (flag) | wall_jump_record position/angle limits the next slide's start | 0 occurrences in JSON; rearm_ticks 3 is a tick delay, not position/angle limits | implement record flag or record as accepted gap |
| WL-09 | SHOULD-FIX | wall_slide (absent) | →jump_wall on spin_valid, pri 26, recorded 20 u below, face away | no spin transition (spin.valid probe exists, e.g. GR-04) | add T6 pri 26 spin.valid → jump_wall |
| WL-11 | SHOULD-FIX | ceiling_hang.T1 | →fall on crouch_press **or hang surface ends**, pri 30 | crouch_press only, pri 30 | add ceiling.available==false → fall (probe exists) |
| WL-03 | CONVENTION | ledge_climb.T0 | climb finished, pri 45 | step>=10, duration 10, tag "Slice: climb duration assumed 10 (not printed)" | none — matches fidelity assumption |
| WL-12 | CONVENTION | ceiling_hang.T0 | →jump1 on jump_press **with enough swing energy**, pri 20 | jump_press only, pri 20; no swing guard | none — no swing probe defined anywhere; unimplementable as specified |
| WL-13–21 | CONVENTION | pole_* | pole rows inferred (Gap G35) | implemented as specified | none |
| wall_slide.T1/T2/T3 | CONVENTION | wall_slide | WL-04/05/06 tags (ledge/ceiling/pole), pris 16/17/18 — but wall_slide ∉ L6 | present with correct tags; spec's WL-04 note leaves "which air states check the guard" open (Gap G42) | none; note dive/spindrill carry the same extensions but vault does not — worth a cross-state decision |

**State fields:** wall_slide gravity 0.5 / terminal 4.0 — matches fidelity report's stated assumption ✓ (CONVENTION confirmed). pole_slide gravity 0.8 / terminal 8.0 — untagged choice, CONVENTION (absent from fidelity assumptions list; record it). ledge_climb duration 10 tagged as Slice assumption ✓.
**Correct:** WL-04/05/06 (jump_wall T4/5/6, pris 16/17/18), WL-07 (resp_wall → wall_slide, rearm 3 — see S-032 gap), WL-10 (→fall pri 45), WL-20 (pole_slide→land_sel pri 14).

## §8 — Water (WT)

15 rows: 7 correct / 8 convention (all under Gap G35/G57 — swimming has no usable wiki page) / 0 missing / 0 undocumented. All six water states ascending priority ✓; L7 entries WT-01 (pri 10) before WT-02 (pri 11) ✓.

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| WT-01 | CONVENTION | 18/21 L7 states [0] | water-run guard: surface found & at/above it & (forced-run counter>0 OR hspeed>fast-dash border), pri 10; gp_fall from its 2nd tick only | `water.surface & water.depth<=0.0 & motion.hspeed>=20.0`; NO forced-run alternative; NO state_step guard on gp_fall | record as gap convention; a faithful S-051 would add the forced_run branch |
| WT-02 | CONVENTION | 18/21 L7 states [1] | enters water volume (head or body below surface), pri 11 | `water.surface & water.depth>0.0` | record |
| WT-01/02 | CONVENTION | bounce_entity, spindrill, bonk | L7 explicitly lists them as water-entry sources | zero water transitions on all three | add rows or record deliberate omission in gap register |
| WT-03 | CONVENTION | 15/15 L8 states [0] | walks/pushed into DEEP water, pri 11 | `water.surface & water.depth>0.0` — "deep" := any depth>0 | record threshold convention (shallow handled downstream by WT-15) |
| WT-04/05/06 | CONVENTION | water_plunge [1/2/3] | `submerged` (head below surface) & stick_moved/neutral, pris 45/46/47 | `water.depth>5.0` / `<=5.0` — head-below-surface approximated by 5.0-unit depth threshold | record |
| WT-10 | CONVENTION | water_swim_under [1] | reaches the surface, pri 30 | `water.depth<=1.0` — "surface" threshold convention | record (spec's oxygen-drain note is a damage event, not a transition) |
| WT-14 | CONVENTION | water_run [1] | surface lost OR hspeed below fast-dash border, pri 45 | `any_of(water.surface==false, motion.hspeed<15.0)` — entry border 20.0 vs exit 15.0 creates **un-declared hysteresis** | record |

**Correct:** WT-07 (water_idle[3]); WT-08 (water_swim_surface[4]); WT-09 ([1], crouch-press dive); WT-11 (jump + cap.catch_window>0, pri 39); WT-12 (jump buffer_ticks 4 = file-wide convention for the 5-tick window); WT-13 (water.surface==false); WT-15 (contact.ground → land_sel on all six).
**State fields:** all six states duration_frames=10000, displacement 0.0, author-sourced — spec states no water numbers; no contradiction (G57).
**STALE-DOC (tag provenance):** several `source_tag`s claim `[D-rule]` where the spec source column says P-shape + Gap G35 (WT-03/04/05/06, WT-11 [W-rule + G35], WT-12 [P-shape + D-num + G35]); WT-01/02/14 `[D-rule]` tags are consistent. Fix the tags.

## §9 — Cap throws and cap machine (CP)

25 rows: 12 correct / 6 wrong / 1 missing / 6 out-of-scope-absent-correct. All 10 states ascending priority ✓. No untagged transitions. `behavior_transitions: []` — cross-machine coupling is blackboard-only (Cap writes cap.state; Nerves reads cap.state/cap.touch/cap.catch_window/cap.spin_used; cap.touch is bridge-fed, no JSON writes).

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| CP-02 | MUST-FIX | Nerves.*.CP-02 (13 states) | guard requires **bounce_ability** available; cap "Extended"; contact test A or B | `bounce_ability` occurs 0× anywhere in JSON — guard unimplementable; "Extended" broadened to hover∨flying (inconsistent with CP-01's hover-only); tests A/B collapsed to bridge bool cap.touch | add bounce_ability param + set/clear per flag table; restrict to hover (or justify flying); keep cap.touch as documented convention |
| CP-02 | MUST-FIX | dive, gp_stall, gp_fall (absent) | L10 includes all three; note names dive bounce + ground-pound bounce (test B) | no CP-02 transition in any | add dive→cap_bounce (dive-bounce variant), gp_stall/gp_fall→cap_bounce with test-B-only guard |
| CP-16 | MUST-FIX | Cap.cap_flying[0] | **shake** after home-able tick (24; 20 air; 19 up; 27 down), pri 12 | on_input cap any_pressed ∧ step≥24 (wrong input; no air/kind variants) | use shake; add air variant (20) via throw-context param |
| CP-19 | MUST-FIX | Cap.cap_hover[0] | **shake** → cap_homing, pri 12 | on_input cap any_pressed (wrong input per spec guard) | use shake |
| up/down throws | MUST-FIX | (no throw.kind anywhere) | A3 W-num tables: upthrow 24/19/8/8/28/29; downthrow 57/27/8/8/28/29; rocket-flower rows | no throw.kind param exists; only standard timings modeled | add throw-kind modeling (larger feature) |
| CP-03 | SHOULD-FIX | 12 states have it; vault/bounce_entity/dive missing | L11 → cap_return_spin on jump_press + catch window + ¬spin_used | buffer 4 ✓, catch_window>0 ✓, spin_used==0 ✓; BUT spin_used=1 set on cap_return_spin entry, reset **only** via land_sel enter_params — ledge grab and wall slide don't clear (spec: cleared by ground contact, ledge grab or wall slide) | clear cap.spin_used on ledge_hang/pole_cling/wall_slide entry; add missing L11 rows |
| CP-10 | SHOULD-FIX | Nerves.cap_throw_air[7] | crouch_press ∧ ground≥40 below ∧ age≥23, pri 21 | matches + extra any_of branch ground.dist<0 (treats "no ground" as pound-OK; spec guard strictly ≥40) | remove lt-0 branch or document as convention |
| CP-12 | SHOULD-FIX | Cap.cap_held[0] | throw begins (cap_press OR shake) → cap_flying, pri 10 | cap any_pressed only ("shake" occurs 0× in entire JSON — the input doesn't exist); fires on raw press without requiring the Nerves throw state → desync (e.g. press cap in crouch_idle: cap flies, Mario stays) | add shake input; gate on Nerves throw-state entry or document the approximation |
| CP-15 | SHOULD-FIX | Cap.cap_flying (absent) | flying→returning on wall/ground interruption, pri 11 | no transition; resp_wall/resp_floor null; no cap-collision bridge param | add transition + bridge param (e.g. cap.blocked) or record as engine gap |
| CP-17 | SHOULD-FIX | Cap.cap_flying[1] | fully thrown → hover (34; 30 air; 24 up; 57 down), pri 20 | step≥34 always — air throws hover 4 ticks late (cap machine has no ground/air context) | add throw-context param (e.g. cap.air_throw) selecting 34/30 |
| cap_return height | SHOULD-FIX | jump_cap_return | 197.2–395.2 by hold time (max 394.95 ≈ 395.2 ✓) | min achievable ~137 (release before first tick) / ~159 (1-tick hold) vs spec 197.2 — low end undershoots ~40–60u | min-hold or retuned cut |
| throw events | SHOULD-FIX | cap_throw/cap_throw_air | — | throw.fully_thrown fires at frame 33/29 but CP-08/09/CP-11 thresholds are step≥34/30 | align event/transition frames |
| CP-04 | CONVENTION | cap_return_spin[9] | "brief spin ends" (no printed timing; Gap G34) | step≥20 → fall, duration 20, tag documents "assumed 20 (not printed)" | none |
| CP-22 | CONVENTION | cap_homing[0] | homing→returning, no printed timing | step≥10, tag documents "homing duration assumed" | none |
| CP-20 | CONVENTION | cap_hover[1] | released ∨ hold-out (22–122) → returning, pri 30 | (none_held ∧ step≥22) ∨ step≥122 — 22–122 counted from hover entry; wiki basis ambiguous | none |
| CP-23 | CONVENTION+OK | cap_returning[0] | returning→held when cap reaches Mario, pri 30; opens 11-tick window | step≥20 (tag: "return duration assumed") + on_fire countdown cap.catch_window=11; verified in engine: >0 for exactly 11 ticks ✓ | none |
| G3 | CONVENTION | cap machine | cap flight speed/distance/return speed unknown | frame-count-only model, no speeds/distances | none per G3 |

**Correct:** CP-01 (11/11 L9 states →vault on cap.state==hover ∧ cap.touch); CP-05 (→fall pri 12); CP-06 (crouch_held ∧ age≥24, pri 30; up/down n/a — no throw kinds); CP-07 (jump ∧ age≥13 → jump_select, pri 40; "5 frames earlier for motion throw" n/a); CP-08/09 (age≥34 → run/idle, pris 44/45); CP-11 (step 30 → fall, pri 45).
**Timing-table gaps:** standard ground 34/24/13/13/24/25 — dive-13 and roll-cancel-ledge-dive-25 transitions don't exist (no CP row owns them); standard air 30/20/9/9/23/24 — home-20 hardcoded as 24 (CP-16), jump-9 and dive-9 transitions missing, ledge-dive-24 missing. cap_flying duration_frames=100 is unsourced and unreachable (CP-17 fires at 34) — convention, harmless.
**Coverage:** CP-01 11/11 ✓; CP-02 13/18 (missing vault, bounce_entity, dive, gp_stall, gp_fall, cap_throw_air); CP-03 12/15 (missing vault, bounce_entity, dive). Capture rows CP-13/14/18/21/24/25 confirmed absent ✓ (out of scope).
**jump_cap_return_cut verdict:** LEGITIMATE slice — matches the cut pattern (duration 10000, gravity 4.0, no enter_vy); SLICE-CUT entry (jump none_held, pri 20, tied with AR-03 listed first) implements hold-to-vary height. No contradiction. (Contrast §5: long/back/side/spin cuts contradict fixed heights.)

**Cross-section note:** all 9 ground throw entries (GR-02) and uncrouch/roll/gp_land entries fire on bare cap-press with **no cap.state==held guard**; the 16 air AR-03 entries all include it. MUST-FIX is CP-02's bounce_ability; the missing cap_held conjunct on ground throws is §3 GR-02 SHOULD-FIX.

## §10 — Special states (SP)

20 in-scope rows: 9 correct / 5 wrong / 6 missing. (SP-14/15/23/24/25/26/27 confirmed N/A — out-of-scope targets.)

| ID | Sev | Location | Spec says | JSON does | Fix |
|---|---|---|---|---|---|
| SP-03 | MUST-FIX | knockback, knockback_land (absent) | →crouch_idle if ceiling too low to stand, pri 15 | missing | add; needs headroom probe (Gap G41-adjacent) |
| SP-16 | MUST-FIX | slope_slide (absent) | slope_slide→fall when no standable ground, pri 12 | only exit is AR-01→land_sel | add |
| SP-17 | MUST-FIX | slope_slide (absent) | slope_slide→jump_select on jump_press (not forced-slide), pri 40 | missing | add |
| SP-18 | MUST-FIX | slope_slide (absent) | slope_slide→run on end condition + stick_moved, pri 44 | missing | add |
| SP-19 | MUST-FIX | slope_slide (absent) | slope_slide→idle on end condition + stick_neutral, pri 45 | missing | add |
| SP-21 | MUST-FIX | sand_sink (absent) | sand_sink→dead after sand death time, pri 20 | sand_sink has no →dead | add |
| SP-02 | SHOULD-FIX | knockback | →knockback_land when touching ground **flatter than stand angle**, pri 14 | contact.ground==true, no slope check | add ground-flatness condition |
| SP-11 | SHOULD-FIX | held | →fall, **end type: with a fall**, pri 13 | tag says SP-11 pri 13 but guard is `state_step>=300` timeout, not an end-type | replace timeout with end-type guard or record gap |
| SP-12 | SHOULD-FIX | pit_fall | →dead at pit-death delay, pri **20** | →dead @ step 60 (slice), pri **10** | pri 10→20 |
| SP-13 | SHOULD-FIX | pit_recover | →idle when recovery finished, pri **45** | →idle @ step 30 (slice), pri **10** | pri 10→45 |
| SP-20 | SHOULD-FIX | G-gnd-sand→slope_slide | crouch_held on ground steeper than angle_start, or forced-slide surface, pri **15** | SLOPE tag, pri **48**, guard = surface.steep only (drops crouch_held, angle_start, forced-slide) | restore guard terms; pri 48→15 |
| SP-22 | SHOULD-FIX | sand_sink | →idle when **Mario leaves the sand surface**, pri 45 | SAND-DONE: →idle @ state_step≥120 timer, pri 45 | guard should be surface.sand==false, not a timer |

**Correct:** SP-01 (dead→idle @ 120, pri 10 — 120 is a documented slice, spec Gap G24 silent); SP-04 (knockback→fall @ 120, pri 45); SP-05/06 (knockback_land→jump_select/run @ step≥45, pris 40/44, buffer 4 ✓, radius 0.1 ✓); SP-07 (→idle @ 60, pri 45 — slice assumption documented in tag); SP-08/09/10 (held→fall/jump1/cap_throw_air, pris 10/11/12 ✓).
In-state priority order ascending everywhere ✓.

## §11 — Steering rules (9 rules)

Steering lives in per-state `steer` blocks (input_turn_rate_deg/displacement are 0.0 with author displacement_source).

| Rule | Verdict | Detail |
|---|---|---|
| Run | OK (partial) | cap = 11·r+3 ✓; decay 0.1167 ✓; turn tiers 6.5 / 22.5−speed / 8.5 ✓; deadzone 0.5° ✓; accel fracs 0.05/0.2, 45°/95° ✓. Ice variant (0.233 accel, no brake/pivot) not encodable — no surface.ice param (CONVENTION) |
| Pivot | SHOULD-FIX | spec: 2-tick wait, ω=0.1·step·angle, full turn by tick 10. JSON: flat 20°/tick cap, no schedule, no wait |
| Crouch walk | SHOULD-FIX-lite | 3.5 u/fr ✓, turn cap 30 ✓; turn accel 3°/fr² not encoded |
| Crouch slide | SHOULD-FIX-lite | decay 5% ✓, gravity 1.5 ✓, side accel 0.25 ✓; sideways decay 7% and grounded −3 u/fr missing |
| Roll | SHOULD-FIX | decay 0.2% ✓, cap 35 ✓, turn ≤5° ✓; **sideways 0.4·radius drift missing** |
| Ground spin | SHOULD-FIX | **no steer block at all** — v=0.95v+0.5·r cap 8 and facing=velocity rules absent; engine has no body for this state |
| Air (vectoring/facing) | SHOULD-FIX (3 spots) | 0.5/1.0/0.3 accel ✓, quickturn 135°/25° ✓, cap 7.5·r∈[1.5,6] ✓, deadzone 1.0 ✓. WRONG: `jump_side` accel_side 0.3 (**spec 0.075**, speedflip); `jump_long`+`dive` face_mode "stick" (spec: facing=velocity angle); `jump_side` face_mode "stick" (spec: no midair facing control) |
| Wall slide | SHOULD-FIX-lite | gravity 0.5 / terminal 4 ✓; "small L/R stick movement" not encoded |
| Knockback | SHOULD-FIX | spec D-num damage.gravity_damage=0.95; knockback has **no steer block** (the only 0.95 in the file is jump_wall's gravity) |

**Struck by coordinator (§14.2):** the claim that fixed-height jump `enter_vy` values "systematically overshoot wiki heights ~4–5%" — wrong formula. Under the engine's decrement-then-integrate scheme (peak = v²/2g − v/2), jump1 31.35→312 ✓, jump2 33.0→346.5 ✓, jump3 41.37→550 ✓, jump_gp 39.98→513 ✓, back/side/vault 39.33→496 ✓, jump_spin 39.1→490 ✓, jump_long 21.54→144 ✓, cap_return 35.18→395 ✓ — all match spec heights (independently verified by the JP worker).

## §12 — Technique paths, parameters, top-level keys

**Technique paths:** T01 ✓, T03 ✓, T04 ✓, T05 ✓, T07–T14 ✓, T17 ✓.
- T02 BROKEN (SHOULD-FIX): `dive→fall` missing (non-slippery slope end); `dive→cap_throw_air` also missing though Gap G50 says "the model uses the air throw".
- T06 BROKEN (SHOULD-FIX): `cap_throw_air→cap_bounce` missing (CP-02 exists on jump1/2/3/fall/jump_wall/etc. but **not** cap_throw_air — bounce off an air throw impossible); `cap_bounce→wall_slide` missing (too-close case).
- T16 BROKEN (SHOULD-FIX): `jump_wall→wall_slide` missing — spec: the wall jump re-checks the slide guard every tick so walls chain without landing.
- T15 N/A (out-of-scope states); `cap_hover→cap_homing` present.

**Parameters (35):** the JSON has exactly the 35; the fidelity report's bridge-fed (25) + engine-managed (10) lists verified accurate. All have typed defaults, no nulls. Issues:
- `bounce.height` — **DEAD** (SHOULD-FIX): 0 reads, 0 writes; default 300.0 meaningless. (Tied to §6 cap-bounce MUST-FIX.)
- `chain.ground_window` — **write-only** (SHOULD-FIX): land_sel arms a 9-tick countdown but nothing reads it → the 9-tick chain-break is unenforced; no transition clears chain.state.
- `jump.origin` — live: 13 writers (ground→jump_select on_fire_params), 4 readers (JP-02/03/04/05). STALE-DOC: fidelity report Known Issue #4 ("Origin flag: Omitted") is false — origin is implemented. Minor: G-jumpable members `water_run` and `wall_push`→jump_select do NOT set jump.origin (SHOULD-FIX-lite).
- Bridge-fed probes with **no in-repo feeder** (game must set): cap.touch, water.surface/depth, bounce.contact, ledge/pole/ceiling.available, pole.top, damage.*, life.zero, held.object, pit.*, surface.*. playground.gd sets only `ground.dist`; the GDExtension driver sets contact.ground/wall, motion.hspeed, fall.distance, stick.up/down.

**Top-level keys:** `behavior_transitions: []` (no behavior-level transitions; interrupts live in per-state GL rows — matches design); `spin_detect` matches spec exactly (31–70 ticks, ±45.57°, area ±5 sq u, 30-tick buffer → spin.valid) ✓; `on_enter_event`/`on_exit_event` unused ("").

## §13 — Fidelity-report staleness (doc dated 2026-10-19; JSON modified 2026-11-03)

| # | Claim | Status |
|---|---|---|
| Known Issue #4 | "Origin flag: Omitted (slice-model call)" | **STALE — origin is implemented** (13 writers, 4 readers) |
| Known Issue #1 + Next Step #2 | "C2 NOT IMPLEMENTED — jump pressed same tick as run start fires immediately" | **STALE — C2 implemented** via GR-06 (pri 39) before GR-05 + unconsumed buffer |
| JP-08 note | "omits 'moving on last tick', cap/sideflip clauses" | **STALE — JP-08 is now opaque `smo.triple_ok`; unverifiable by inspection** |
| Known Issue #3 | "G-hurt coverage: GL-01..07 wired on idle/run/fall only" | Still accurate |
| Known Issue #2 | "AR-02 trigger via bounce.contact needs bridge verification" | Still accurate — and worse: bounce.height is dead (§12) |
| "418/418 source tags, 0 missing" | — | Now 423/423 (5 PLAYGROUND-FIX rows added, all tagged) |
| "68 + 8 cut, 11 out-of-scope" | — | Verified exact |
| Assumptions list (timings/physics/guards) | — | Verified current for: wall_slide 0.5/4.0, ledge_climb 10, cap_return_spin 20, CR-04 guard, AR-27 ambiguity, SAND/SLOPE slice rows. **Gap:** pole_slide gravity 0.8 / terminal 8.0 is an untagged assumption missing from the list |

## §14 — Coordinator corrections to worker findings (verified against `tick.rs` / spec)

1. **AR "durations" off-by-one — STRUCK.** The worker claimed `state_step>=N` fires after N+1 ticks. `tick.rs` `advance_frame` skips the increment for `just_entered` tracks "so frame 0 emits exactly once"; tracing both Phase-A and Phase-B entries, `state_step>=N` yields exactly N ticks. The JSON's `step>=12/30/30/60/20/10` matches the documented slice durations exactly. The associated STALE-DOC is likewise struck. (The CR/RL and GL+GR workers independently verified the correct semantics.)
2. **SP "jump heights overshoot 4–5%" — STRUCK.** The worker used the continuous formula v²/2gh; the engine integrates decrement-then-integrate, for which peak = v²/2g − v/2. All fixed-height `enter_vy` values reproduce spec heights exactly (JP worker validated: 312/346.5/550/513/496/490/144/395.2).
3. **GL+GR GR-14/15/16b/24 timing MUST-FIXes — STRUCK.** Same N-vs-N+1 error: `ge 11/13/10` = 11/13/10 ticks ✓ matches spec ("brake lasts 11 ticks", "opposite way after 13 ticks", "at most 10 frames"). The anchor tests (`smo_p0.rs` brake_stop_timing etc.) encode the correct values — do not "fix" these.
4. **GR-08/09/19/25/26/27/28 — downgraded to SCOPE.** talk/fp_* are documented out-of-scope (fidelity report), not missing bugs.
5. **GL-09/10 — downgraded to CONVENTION.** Targets auto_run/auto_dash are out of scope (Gap G26).
6. **GR-20/21 — downgraded to CONVENTION.** Superseded by Joey's 2026-11-03 wall_push redesign (standing user override), implemented as PLAYGROUND-FIX rows.

## §15 — Consolidated MUST-FIX list (priority order)

1. **RL-08** — roll/roll_standup have no ground-loss exit (§4). Rolling off a ledge is a dead end.
2. **RL-02** — roll boost system unimplemented: no 23/26/29 floors, no failed-boost 20 floor, no shake, flat 16-tick first boost even for pound entries (need 32) (§4).
3. **gp_fall terminal 60 vs 45** — live physics error (§6).
4. **Cap-bounce system** — CP-02's `bounce_ability` guard references a param that doesn't exist; variant heights (231/300/390.5/325) and speed caps (16/24/14) unimplemented; `bounce.height` dead; `bounce.contact` fed by nothing (§6, §9, §12).
5. **AR-06** — spindrill cancel → jump_spin re-arms upward `enter_vy` 39.1 instead of 35 u/fr downward (§5).
6. **GR-04** — priority inversion: spin (tagged 21, spec 35) listed before crouch GR-03 (spec 30); crouch must win (§3).
7. **JP-03/JP-04** — selector origin guards: moving crouch_slide→long jump needs forward-speed>0 + coyote bound; stationary-slide and braking-coyote →backflip alternatives missing (§5).
8. **Up/down throw tables missing** — no throw.kind; upthrow 24/19/8/8/28/29 and downthrow 57/27/8/8/28/29 entirely unmodeled (§9).
9. **slope_slide exits** — SP-16/17/18/19 missing; only →land_sel exists (§10).
10. **GL coverage** — death/damage/pit interrupts on 3/71 states (spec: all live states); PLAYGROUND-FIX rows sort ahead of GL-01 (run→roll evaluated before life.zero→dead) (§2, §3).

**Strong runners-up:** RL-01 (forced-roll rows absent everywhere); jump_wall input_lock=25 never set; wall_jump_record (D-rule S-032) unimplemented; jump_cap_return low-end height undershoot (~40–60u); `chain.ground_window` write-only (9-tick chain break unenforced); CP-16/CP-19 homing triggers use cap-press instead of shake (shake input doesn't exist anywhere in the JSON); WL-09 spin→wall-jump missing; T02/T06/T16 broken technique links; SP-21 sand_sink→dead missing.
