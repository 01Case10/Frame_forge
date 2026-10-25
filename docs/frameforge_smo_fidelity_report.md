# SMO Controller — Fidelity Report

**Behavior:** `smo_movement.json` (SMOMovement)
**Date:** 2026-10-19
**Spec:** `~/workspace/frameforge-smo/spec/smo_states.json` (79 states, 187 transitions)

## Coverage

| Metric | Spec | Implemented | Notes |
|--------|------|-------------|-------|
| States | 79 | 76 (71 Nerves + 5 Cap) | 68 spec + 8 cut variants |
| In-scope states | 68 | 68 | 100% |
| Out-of-scope | 11 | 0 | See below |
| Transitions (rows) | 187 | 418 | Includes per-state expansions + slice rows |
| Source tags | — | 418/418 | 0 missing |

**Out-of-scope states (11):**
- Cutscene/dialogue (4): talk, fp_start, fp_wait, fp_end — not movement.
- Capture (4): cap_latched, cap_p2, capture_flyin, captured — doc says 52 kinds, out of scope v1.
- Scripted (2): auto_run, auto_dash — Gap G26, not player-controlled.
- Name-only (1): updraft — basis N, needs volume probe.

**Slice-model additions (8):** jump1_cut, jump2_cut, jump3_cut, jump_long_cut, jump_back_cut, jump_side_cut, jump_spin_cut, jump_cap_return_cut — implement hold/release via `none_held` (pure level check). Not in spec.

## Conventions (C1–C4)

- **C1:** Same-tick transition semantics (FrameForge fires during row eval; new state's delta applies same tick). Doc's next-tick model (Gap G28) resolved by convention.
- **C2:** NOT IMPLEMENTED. Jump pressed same tick as run start should delay 1 tick (doc: GR-05 pri 40 > GR-06 pri 45). Currently GR-05 fires immediately.
- **C3:** Crouch pressed same tick as run start delayed 1 frame. Implemented via row ordering.
- **C4:** Cap throw overrides run immediately (GR-02 pri 20 > GR-06 pri 45). Implemented.

## Slice-Model Assumptions (31 rows)

Documented per-row with "Slice:" or "assumed" in source_tag:

**Timings (not printed in doc):**
- ledge_climb: 10 ticks
- gp_stall: 12 ticks (AR-10)
- gp_land: 30 ticks (AR-16)
- bonk: 30 ticks (AR-18)
- land_hard: 60 ticks (AR-17)
- cap_return_spin: 20 ticks (CP-04)
- knockback_land: 60 ticks (SP-07)
- dead: 120 ticks (SP-01, respawn)
- pit_fall: 60 ticks (SP-12)
- pit_recover: 30 ticks (SP-13)
- sand_sink: 120 ticks

**Physics (not printed):**
- run accel_forward: 1.0 (assumed)
- jump gravity: 1.5 (not printed; v0 tuned to doc heights)
- pivot: 20°/tick immediate (doc: 2-tick wait + 0.1×step×angle schedule)
- pivot_moving: 1.4 u/fr setup cost omitted
- wall_slide gravity: 0.5, terminal 4.0 (assumed)
- spindrill: 36.5 down, +1.5/fr to 45 (from doc)

**Guards (simplified):**
- GR-17 (pivot_moving→run): 15° assumed (doc: "velocity shifted to stick direction")
- CR-04 (stand-up): guard assumed true (no ceilings in slice)
- JP-08 (triple): omits "moving on last tick", cap/sideflip clauses
- AR-27 (pivot_moving_ok): ambiguous guard, implemented parse documented
- SAND/SLOPE: simplified, doc has no transition ID
- AR-02 (bounce): trigger via `bounce.contact` param needs bridge verification

## Bridge-Fed Probes (35 params)

The embedder (Godot) must provide these per tick:

**Contact:** `contact.ground` (bool), `contact.wall` (bool), `ground.dist` (float, -1=none)
**Motion:** `motion.hspeed` (float), `fall.distance` (float, persists through landing tick)
**Water:** `water.surface` (bool), `water.depth` (float)
**Hang:** `ledge.available`, `pole.available`, `ceiling.available`, `pole.top` (all bool)
**Stick:** `stick.up`, `stick.down` (bool, derived from stick Y)
**Damage:** `damage.event`, `damage.ground`, `life.zero`, `held.object` (all bool)
**Pit:** `pit.below`, `pit.safe` (bool)
**Surface:** `surface.steep`, `surface.sand` (bool)
**Bounce:** `bounce.contact` (bool), `bounce.height` (float)
**Cap:** `cap.state` (string), `cap.touch` (bool)

**Engine-managed (do not set):** `chain.state`, `chain.ground_window`, `air.from`, `jump.pound_ok`, `quickturn.latch`, `cap.catch_window`, `cap.spin_used`, `spin.valid`, `jump.origin`, `always`

## Known Issues

1. **C2 not implemented:** Jump+run same tick should delay jump 1 tick. Currently fires immediately.
2. **AR-02 trigger:** `bounce.contact` param path unverified in harness; state defined correctly.
3. **G-hurt coverage:** GL-01..07 wired on idle/run/fall only (representatives). Full "all states" coverage needs bridge-driven forcing or per-state rows.
4. **Origin flag:** Omitted (slice-model call).
5. **contact.ground:** Embedder-fed (G-7 probe); no auto-detection.

## Test Status

- 52/52 anchor tests green (smo_p0.rs)
- 139/139 full suite green
- Zero clippy warnings
- `ff check` clean

## Next Steps

1. **GDExtension wiring:** Expose `set_stick`, contact probes, and param setters on BehaviorPlayer. Wire spin detector predicates.
2. **C2 implementation:** 1-tick jump delay on run start.
3. **Fidelity validation:** Differential tests vs. doc constants (heights, timings, speeds).
