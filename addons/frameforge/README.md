# FrameForge

Author kinematic platformer movement as **frame data in hierarchical state
machines**, ticked at a canonical 60 Hz. No physics tuning, no per-frame
code — every motion is authored displacement, and the runtime just plays it.

## Concepts

- **FrameState** — one node of movement: `displacement` (units) along
  `direction`, over `duration_frames`, shaped by an easing `Curve`.
  Everything is *relative*: a state only says how far it moves from where
  it started, so chains blend seamlessly.
- **SubStateMachine** — a flat graph of states with ordered transition rows.
  Rows carry one condition each (On Complete / On Input / On Variable /
  On Event / On State / On Custom), evaluated top-down per tick; the first
  true row wins.
- **Behavior** — a set of sub-machines that run **in parallel**, their
  per-frame deltas summed. Jump = vertical track + air-horizontal track.
  Behaviors switch whole sets at once (ground ↔ air).
- **Blackboard** — designer-declared typed parameters on the behavior;
  the game writes them via `player.set_param("speed", 3.2)` and On Variable
  rows read them.
- **Events** — states fire named events on enter / exit / frame N;
  transitions can fire events; the player emits `state_entered`,
  `state_exited`, `behavior_changed`, `event_fired` signals for animation
  and audio systems.

Special sources make common idioms one state:

- `ENTRY` — the entering sub-machine's pre-entry tick delta (brake-from-any-speed,
  landing skids, long jump from run speed).
- `INPUT` — camera-relative analog steering from InputMap actions.
- `IMPACT_NORMAL` / `REFLECTED` / `INCOMING` — wall kicks and bounces authored
  from collision data, with per-response `rearm_ticks` debounce.

## Documentation

Full feature list, API, setup walkthrough, and the two example
implementations (Odyssey-style and SM64): see
[`docs/README.md`](../../docs/README.md).

## Install

1. Copy `addons/frameforge` into your project.
2. Enable **FrameForge** in Project → Project Settings → Plugins.
3. A **FrameForge** tab appears in the main screen.

## Quick start

1. Open the FrameForge tab → **New**. You get one sub-machine with one state.
2. Right-click the canvas → **Add State**; drag the row port (right side of
   a state) onto another state's input to wire a transition.
3. Click a transition row to edit its condition in the Inspector.
4. **Save** → `my_behavior.json` (JSON is the canonical format).
5. In your scene: add a `BehaviorPlayer` (a `CharacterBody3D`), assign the
   behavior, and it moves at 60 Hz. Feed it with `set_param()` and react to
   its signals.

Toolbar: sub-machine tabs · frames/seconds toggle · snap · **Validate**
(diagnostics run on every save too) · **Preview** (steps the player and
highlights the active state, with an event monitor).

## Samples

`samples/` holds hand-authored behaviors:

- `jump_demo_ground.tres` / `jump_demo_air.tres` — run/idle/brake on the
  ground, rise/fall/drift in the air, jump switches behaviors, landing
  comes back on the `floor_gained` contact event. Uses only the built-in
  `ui_*` input actions. Rebuild with
  `godot --headless --path . --script res://samples/build_jump_demo.gd`.

## Runtime API

```gdscript
player.set_param("speed", 4.0)
player.get_param("speed")
player.emit_event("stomp")            # game → behavior
player.current_state_name("Vertical") # parallel-machine query
player.switch_behavior(air_behavior)  # scripted behavior swap
```

Signals: `state_entered(behavior, machine, state)`,
`state_exited(behavior, machine, state)`,
`behavior_changed(old, new)`, `event_fired(event_name)`.

## Testing

Headless suites live in `tests/`:

```
for t in phase1_runner phase2_runner phase3_runner phase5_runner; do
  godot --headless --path . res://tests/$t.tscn   # phase5 uses --script
done
```

58 checks green across runtime core, conditions, collision, events,
and validation.

## Layout

```
addons/frameforge/
  plugin.cfg / plugin.gd        # EditorPlugin, main-screen tab
  runtime/                      # FrameState, FFTransition, FFCondition,
                                # FFResponse, FFParameter, FFStateEvent,
                                # FFComment, SubStateMachine,
                                # FrameBehavior, BehaviorPlayer
  editor/                       # behavior_editor, behavior_overview,
                                # sub_machine_graph, state_graph_node,
                                # event_monitor, validation_panel,
                                # ff_validator
```

Full design doc: `~/workspace/your_files/frameforge_plan.md`
(or the goal workspace copy).

## Phase 7 exit gate (stepkit differential)

The ship gate recreates stepkit's moveset differentially:

- **7a harness** (`exit_gate/run_gate.tscn`): replays a FrameForge behavior
  against stepkit CLI oracle CSVs, comparing 3D positions per frame.
  Tolerances (stepkit cm): mean < 0.5, max < 2.0, final < 1.0.
- **7b baker** (`exit_gate/bake.py`, `build_baked.gd`): JSON scenario → RON →
  stepkit CLI → 60 Hz `.tres` state chains (2 ticks per 30 Hz sim frame).
- **7c hand-authored Tier 1**: walk (straight/brake/turn), single/double
  jump with landing chains, ground pound, long jump — all PASS. Backflip,
  wall kick via baked chains (exact).

New runtime primitive: `FrameState.input_turn_rate_deg` (INPUT direction
rotates toward requested heading at N°/tick; enables turn-in-place).

## Tick rate

`BehaviorPlayer.tick_rate_hz` (default 60) controls the behavior clock,
exposed in the inspector. The player accumulates physics time and ticks at
this rate — set to 30 to play 30Hz-authored content at its native speed.

## Rust rewrite (2026-10-18)

The runtime core is ported to Rust (`rust/` workspace):

- **`frameforge-core`** — pure Rust, zero Godot dependency: the behavior
  model (serde JSON), Godot `Curve` sampling (exact port), the tick engine
  (faithful port of `behavior_player.gd`), input edges, and the validator.
- **`frameforge-cli`** (`ff`) — `diff` (14 differential harness),
  `dump` (per-tick CSV traces), `check` (validator), `bake` (scenario →
  baked chain, absorbs `bake.py`).
- **`frameforge-godot`** — GDExtension `BehaviorPlayer` node (thin wrapper
  over the core).

**Behaviors are JSON-canonical** (`rust/behaviors/*.json`). The Godot editor
loads/saves `.json` via `BehaviorJSON` (`addons/frameforge/editor/behavior_json.gd`).
The old `.tres` format is superseded.

**Verification:** 14/14 differentials pass in pure Rust *and* through the
GDExtension in headless Godot; 157/157 Rust tests green (workspace).
See `rust/README.md` and `~/workspace/your_files/frameforge_rust_plan.md`.
