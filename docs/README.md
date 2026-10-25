# FrameForge

**Author kinematic platformer movement as frame data in hierarchical state
machines, ticked at a canonical 60 Hz.** No physics tuning, no per-frame
gameplay code — every motion is authored displacement, and the runtime just
plays it.

A pure-Rust core (`frameforge-core`) drives everything; a thin GDExtension
(`BehaviorPlayer`, a `CharacterBody3D`) runs it in Godot; an editor addon
provides the graph authoring tab; a headless CLI (`ff`) validates, dumps,
bakes, and differential-tests behaviors. Behaviors are JSON — the canonical
format, hand-editable and version-controllable.

## How it works

- **FrameState** — one node of movement: `displacement` (units) along
  `direction`, over `duration_frames`, shaped by an easing `Curve`.
  Everything is *relative*: a state only says how far it moves from where
  it started, so chains blend seamlessly.
- **SubStateMachine** — a flat graph of states with ordered transition
  rows. Rows carry one condition each and are evaluated top-to-bottom per
  tick; the first true row wins.
- **Behavior** — a set of sub-machines that run **in parallel**, their
  per-tick deltas summed. Jump = vertical track + air-horizontal track.
  Behaviors switch whole sets at once (ground ↔ air).
- **Blackboard** — designer-declared typed parameters (`Float`, `Int`,
  `Bool`, `String`, `Vec3`): the game writes them via `set_param()` and
  On Variable rows read them. Values serialize bare in JSON (`1.5`, `"x"`,
  `[x,y,z]`).
- **Events** — states fire named events on enter / exit / frame N;
  transitions fire events; the engine fires contact-edge events
  (`floor_gained`, `wall_gained`, …); the game can inject events with
  `emit_event()`. The player re-emits everything as Godot signals for
  animation and audio.

Tick order (deterministic, integer frames): begin (rotate events, input
edges, countdown params, spin push) → row evaluation per track → per-track
deltas (easing or G-5 steering) summed → `move_and_slide` → collision pass
(floor > ceiling > wall) → behavior transitions → frame advance → end.

## Transition conditions

`OnComplete` (state finished) · `OnInput` (action pressed/held, with
G-1 buffering) · `OnVariable` (param compare) · `OnEvent` (engine-internal
events; game-injected events arrive the tick *after* `emit_event`) ·
`OnState` (another track's current state) · `OnCustom`
(`register_custom_condition`) · `OnStick` (G-2: stick direction / magnitude
geometry).

## Params and assigns

`ParamAssign` rows (`{"op":"set","name","value"}` / `{"op":"countdown",
"name","ticks"}`) run on state enter (`enter_params`) and on transition
fire (`on_fire_params`). Countdown params tick down −1 per frame — the
standard way to author timers, coyote time, and rearm windows in data.

## Special displacement sources

- `ENTRY` — the entering sub-machine's pre-entry tick delta
  (brake-from-any-speed, landing skids, long jump from run speed).
- `INPUT` — camera-relative analog steering from the stick, via
  `camera_yaw_deg`.
- `IMPACT_NORMAL` / `REFLECTED` / `INCOMING` — wall kicks and bounces
  authored from collision data, with per-response `rearm_ticks` debounce.

## Engine extensions

- **G-1 — input buffering.** Press edges survive N ticks so 60 Hz inputs
  never fall between frames.
- **G-2 — OnStick.** Conditions on stick angle/magnitude, with deadzones.
- **G-3 — state_step.** Frame-N custom events and per-frame timing inside
  states.
- **G-4 — param assigns + spin-gesture detector.** Data-driven assigns
  (above) plus a stick-circle gesture recognizer feeding params.
- **G-5 — steering.** Turn tiers (`FFTurnTier`), `enter_vy` (keep/set/add),
  and a per-tick steering velocity model blended with authored deltas —
  authored arcs that still respond to the stick.
- **G-6 — state logic.** A `logic` field on a state runs Rust code during
  the tick: custom logics via `register_state_logic(name, factory)`, plus
  three built-ins —
  - `wallrun`: runs along the wall at `wallrun_speed` for
    `wallrun_max_ticks`; ends on wall loss, >~25° normal swing, timer, or
    `wallrun.available == false`. Adds the wall's own velocity (moving
    walls carry the player) and sticks slightly into the wall.
  - `ledgegrab`: snaps to `ledgegrab.offset` on enter, hangs with zero
    drift, faces the wall; fires `ledgegrab_climb` (jump or 10 ticks of
    stick-toward) and `ledgegrab_drop` (drop action, stick-away, wall
    lost, optional `max_ticks`).
  - `poleclimb`: snaps to `poleclimb.snap`, climbs at
    `stick_y · poleclimb.speed` while `poleclimb.recenter` glues the
    player to the pole axis; fires `poleclimb_jump` / `poleclimb_top` /
    `poleclimb_drop`.
  
  The contract: **the game does spatial queries, the core does temporal
  logic.** The core is position-agnostic; spatial facts (offsets,
  availability, tags like `no_wallrun` groups) arrive as game-written
  params. Contact velocities are stored in units/sec and converted via
  `*_velocity_per_tick()`. Logics only fire events — transitions stay
  authored in JSON.

## Runtime API (GDExtension)

| Export | Purpose |
|---|---|
| `behavior_path` | `res://` path to the behavior JSON. Loaded on ready; empty = no movement. |
| `tick_rate_hz` | Behavior clock (default 60). |
| `camera_yaw_deg` | Camera yaw for camera-relative `INPUT` steering. |
| `auto_step` | Ticks in `_physics_process`, accumulating real delta. Off = manual `tick()`. |

Functions: `set_param(name, value)` / `get_param(name)` (Vector3 ↔ Vec3
supported) · `emit_event(name)` · `load_behavior(path)` ·
`force_state(machine, state)` ·
`current_state_name(machine)` · `tick_count()` · `set_stick(x, y)` ·
`sync_smo_probes(stick_x, stick_y)` (auto-called in `tick()`; sets
`contact.ground/wall`, `motion.hspeed`, `fall.distance`,
`stick.up/down` — water/hang/damage/pit/surface probes are game-specific
and need `set_param`).

Signals: `state_entered(behavior, machine, state)` ·
`state_exited(behavior, machine, state)` · `behavior_changed(old, new)` ·
`event_fired(event_name)`.

Input: the runtime collects every InputMap action the behavior references
at load and samples it per tick — **action names must match exactly**.
With `auto_step`, the stick comes from Godot's `ui_left/ui_right/ui_up/
ui_down` actions (add your keys there); `set_stick` only takes effect with
manual `tick()` (auto-step re-samples every tick and overwrites it).

## Editor addon

Graph tab: sub-machine tabs, add/wire states, per-row condition editing in
the Inspector, `logic` / `enter_params` / `steer` / `on_fire_params`
fields with full JSON round-trip. **Validate** runs on every save
(unknown `logic` names are hard errors; `steer` + `logic` on one state
warns). **Preview** steps the player and highlights the active state with
an event monitor. Frames/seconds toggle, snap, save/load `.json` directly.

The editor's data model maps 1:1 to the Rust schema — composite conditions
(`all_of` / `any_of`), `on_stick`, `buffer_ticks`, `none_held`, parameter
types, and `spin_detect` all survive a load/save cycle, enforced by the
round-trip gate (`tools/roundtrip_gate.gd` + `tools/roundtrip_diff.py`
over every behavior in `rust/behaviors/`, plus `ff check` on the output).
Preview runs the **Rust GDExtension player** — the only evaluator; the
editor serializes the current behavior to a scratch JSON and
`load_behavior()`s it, so preview behavior is shipping behavior. (The
old GDScript runtime was retired to `legacy/gdscript_runtime/`; the
GDScript resource classes are the editor's document model, not an
evaluator.)

All graph surfaces (grouped map, grouped detail, flat graph) speak the
Unreal state-machine design language (`editor/ue_style.gd`): near-black
canvas, one-piece rounded state cards, flat light lines with
arrowheads, ⇄ transition badges whose condition shows on hover/click,
orange selection, and an ENTRY tag on the entry state. In the grouped
map, lines are uniform; the count chips carry the kind (gold text =
shared rule, counted once).

**Beautify** (grouped view) reorders nodes to cut crossings and is
overlap-free by construction: detail nodes stack on measured heights
(the old estimate undercounted self-loop glyph rows), and both surfaces
arrange on the golden ratio — detail gaps are horizontal clearance :
vertical gap = φ : 1 (58 : 35.85), map box widths make horizontal gap :
vertical gap = φ : 1. No ordering beautify produces can overlap, so the
crossing score needs no overlap term.

## CLI (`ff`)

- `ff check <file>` — validate a behavior JSON.
- `ff diff --behavior B --oracle O` — replay a behavior against a stepkit
  oracle CSV; tolerances (stepkit cm): mean < 0.5, max < 2.0, final < 1.0.
- `ff dump --behavior B --scenario S` — per-tick position trace for
  debugging.
- `ff bake <scenario> --out <file>` — bake a stepkit scenario JSON into a
  behavior JSON chain.

## Validation & determinism

Fixed integer-frame ticks, no floats in authored timing, cross-arch
hash-checked runs. `rust/release-gate.sh` = cargo tests + 14/14 `ff diff`
differentials in pure Rust + 14/14 through the GDExtension in headless
Godot.

## Setup

### Install

```bash
cd rust/frameforge-godot && cargo build --release
```

| File | Destination in your project |
|---|---|
| `target/release/libframeforge_godot.so` | `res://bin/libframeforge_godot.so` |
| `rust/godot_test/frameforge.gdextension` | `res://frameforge.gdextension` |
| `addons/frameforge/` | `res://addons/frameforge/` |

Enable **FrameForge** in Project Settings → Plugins, then restart the
editor so the native class registers. (The addon also ships a legacy
GDScript `BehaviorPlayer` for `.tres` behaviors — no G-6 support. In the
Create Node dialog, pick the extension's native class.)

### Player scene

1. Add a **BehaviorPlayer** node (a `CharacterBody3D`).
2. Add a **CollisionShape3D** child (capsule typical).
3. Set `behavior_path` to your authored JSON (§Authoring), `tick_rate_hz`
   (60), `camera_yaw_deg` (from your camera rig), `auto_step` on.

Movement goes through `move_and_slide()`, so `floor_snap_length`,
`floor_max_angle` (walls steeper than this are *walls* — what the wallrun
logic sees), and collision layers all behave as usual.

### Authoring

FrameForge tab → New → states, rows, `logic` fields → Save → `player.json`
(JSON is canonical — hand-editable; `ff check` validates). Point
`behavior_path` at it. Hot-swap with `load_behavior()`.

### Level geometry & the game-side probe contract

Geometry is always plain Godot: `StaticBody3D` floors/walls, `no_wallrun`
group on walls you can't run on (opt-out — untagged walls are runnable).
Ledges and poles need no special nodes, just a probe script that translates
spatial facts into params (the D9 contract):

**Use thick collision volumes.** The bridge applies each tick's
displacement as a single `move_and_slide()` — no substepping, and
`CharacterBody3D` has no continuous collision detection. A surface thinner
than one tick of travel can be passed through without registering a hit
(verified: a 7 u/tick fall went through a 1-unit floor with zero
collisions). Make floors, ground, and any surface the character can move
fast toward thicker than the largest per-tick displacement your behavior
can produce. For the Odyssey-style reference behavior that is 35 u/tick
at terminal fall velocity, so floors need >35 units of thickness — the
reference scenes use 200-unit-thick floors.

```gdscript
# non-runnable walls, each physics frame:
var runnable := true
if player.is_on_wall():
    for i in player.get_slide_collision_count():
        var col := player.get_slide_collision(i).get_collider()
        if col and col.is_in_group("no_wallrun"):
            runnable = false
player.set_param("wallrun.available", runnable)
# guard the wallrun entry row with: OnVariable wallrun.available == true

# ledges (wall + falling + clearance check), hand over the snap offset:
var avail := false
var offset := Vector3.ZERO
if player.is_on_wall() and player.velocity.y < 0.0:
    var top := player.get_slide_collision(0).get_position() + Vector3.UP * 1.2
    if has_floor_above(top):
        avail = true
        offset = top - player.global_position
player.set_param("ledgegrab.available", avail)
if avail:
    player.set_param("ledgegrab.offset", offset)
# rows: OnVariable ledgegrab.available == true -> Hang (logic="ledgegrab");
# Hang: OnEvent ledgegrab_climb -> authored climb-up state,
#       OnEvent ledgegrab_drop -> Fall.

# poles (group "climbable_pole"); on grab:
player.set_param("poleclimb.available", true)
player.set_param("poleclimb.snap", grab_pose_position - player.global_position)
# while climbing, every physics frame:
var axis := pole.global_position
player.set_param("poleclimb.recenter",
    Vector3(axis.x - player.global_position.x, 0.0,
            axis.z - player.global_position.z))
player.set_param("poleclimb.top", player.global_position.y >= pole_top_y)
# rows on the Pole state consume poleclimb_jump / poleclimb_top / poleclimb_drop.
```

Set params in `_physics_process` before the player ticks (mind node order).

### Troubleshooting

- **Doesn't move** → `behavior_path` empty/wrong, or no displacement states.
- **Input dead** → action name ≠ Input Map name (case-sensitive); or
  `set_stick` with `auto_step` on (overwritten — use `ui_*` or manual ticks).
- **Wallrun never triggers** → wall shallower than `floor_max_angle` is floor.
- **Falls through the floor** → floor collision thinner than one tick of
  fall travel; thicken it (see Level geometry above).
- **Ledge/pole idle** → probe params not set, or set after the tick.
- **Hand-edited JSON suspect** → `ff check`.

## Examples

### Example 1 — Mario Odyssey-style controller

`rust/behaviors/smo_movement.json`: a 76-state / 418-row transcription of
an Odyssey-style moveset (79 spec states; cutscene/capture/scripted
variants out of scope), running at 60 Hz on the stock engine plus the G-1…
G-5 extensions. The GDExtension bridge (`set_stick`, `sync_smo_probes`,
`force_state`) feeds engine-known probes; water/hang/damage/pit/surface
probes are game-side `set_param`s. Conventions C1–C4 pin same-tick
transition semantics and the run-start jump/crouch delays. Fidelity report:
`docs/frameforge_smo_fidelity_report.md` (418/418 rows tagged, assumptions
and probes listed). Exercised by `rust/frameforge-core/tests/smo_p0.rs`.

### Example 2 — Mario 64 moveset recreation (differential-tested)

`rust/behaviors/*.json` (`walk`, `move`, `double_jump`,
`triple_jump_baked`, `long_jump`(+chain), `wall_kick_chain`,
`backflip_chain`, `ground_pound`): the SM64 moveset recreated as
FrameForge behaviors and replayed **tick-for-tick against the StepKit SM64
sim oracle** — 14/14 differential scenarios green (mean < 0.5 cm, max <
2.0 cm, final < 1.0 cm), in pure Rust and through the GDExtension in
headless Godot, via `ff diff` and `rust/release-gate.sh`. The gate's
scenarios, oracles, and baked behaviors live in `exit_gate/`.

## Docs

- `docs/README.md` — this file.
- `docs/frameforge_smo_fidelity_report.md` — SMO transcription fidelity.
- `addons/frameforge/README.md` — addon install + quick start.
