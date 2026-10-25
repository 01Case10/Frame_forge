extends Node
## Bridge verification for known issue #7: the SMO OnCustom predicates
## (smo.double_ok / smo.triple_ok / smo.pivot_moving_ok) registered by the
## GDExtension. Mirrors the Rust Rig anchors in
## frameforge-core/tests/smo_p0.rs (chain_single_double_triple JP-10/JP-08,
## landing_stick_back_pivot_moving AR-27) through the real Godot bridge.
## Prints PASS/FAIL lines and a final verdict, then quits.

var player: BehaviorPlayer
var phase := 0
var settle_ticks := 0
var failures := 0

func _ready() -> void:
    for a in ["jump", "crouch", "cap", "ui_left", "ui_right", "ui_up", "ui_down"]:
        if not InputMap.has_action(a):
            InputMap.add_action(a)
    player = BehaviorPlayer.new()
    player.behavior_path = "res://behaviors/smo_movement.json"
    player.auto_step = false
    player.position = Vector3(0, 0.1, 0)
    var col = CollisionShape3D.new()
    var capsule = CapsuleShape3D.new()
    capsule.radius = 0.4
    capsule.height = 1.8
    col.shape = capsule
    col.position = Vector3(0, 0.9, 0)
    player.add_child(col)
    add_child(player)

func state() -> String:
    return player.current_state_name("Nerves")

func check(cond: bool, label: String) -> void:
    if cond:
        print("PASS: ", label)
    else:
        failures += 1
        print("FAIL: ", label, " (state=", state(),
              ", chain.state=", player.get_param("chain.state"),
              ", chain.ground_window=", player.get_param("chain.ground_window"),
              ", air.from=", player.get_param("air.from"), ")")

func tick(n := 1) -> void:
    for i in n:
        player.tick()

## Tick (stick untouched) until `target` is the current state.
func wait_state(target: String, max_ticks: int) -> bool:
    for i in max_ticks:
        if state() == target:
            return true
        player.tick()
    return state() == target

## One-tick jump press; leaves the player in the state the release tick
## resolves to (jump_select fires on the press tick).
func tap_jump() -> void:
    Input.action_press("jump", 1.0)
    player.tick()
    Input.action_release("jump")
    player.tick()

func _physics_process(_delta: float) -> void:
    if phase == 0:
        if state() != "<none>":
            player.velocity = Vector3.ZERO
            player.move_and_slide()
            phase = 1
        return
    if phase == 1:
        player.tick()
        settle_ticks += 1
        if settle_ticks >= 30 and state() == "idle":
            phase = 2
        elif settle_ticks >= 120:
            print("Settle fallback, state=", state())
            phase = 2
        return
    if phase == 2:
        phase = 3
        run_test()
        if failures == 0:
            print("PRED TEST: ALL PASS")
        else:
            print("PRED TEST: ", failures, " FAILURES")
        get_tree().quit()

func run_test() -> void:
    # --- Chain: run -> jump1 -> land -> jump2 -> land -> jump3 (JP-10/JP-08)
    Input.action_press("ui_up", 1.0)  # stick [0, 1] forward, held throughout
    tick(20)
    check(state() == "run", "run after 20 ticks at full stick")

    Input.action_press("jump", 1.0)
    player.tick()
    check(state() == "jump_select", "jump press -> jump_select")
    Input.action_release("jump")
    player.tick()
    check(state() == "jump1", "first jump -> jump1")
    check(wait_state("land_sel", 200), "jump1 lands -> land_sel")
    tick(3)
    check(int(player.get_param("chain.state")) == 1, "chain.state == 1 after jump1 land")

    Input.action_press("jump", 1.0)
    player.tick()
    check(state() == "jump_select", "second jump press -> jump_select")
    Input.action_release("jump")
    player.tick()
    check(state() == "jump2", "quick second jump -> jump2 (smo.double_ok)")
    check(int(player.get_param("chain.state")) == 2, "chain.state == 2 in jump2")
    check(wait_state("land_sel", 200), "jump2 lands -> land_sel")
    tick(2)

    Input.action_press("jump", 1.0)
    player.tick()
    check(state() == "jump_select", "third jump press -> jump_select")
    Input.action_release("jump")
    player.tick()
    check(state() == "jump3", "third jump -> jump3 (smo.triple_ok)")
    check(int(player.get_param("chain.state")) == 0, "chain.state resets in jump3")
    check(wait_state("land_sel", 200), "jump3 lands -> land_sel")

    # --- Moving pivot (AR-27): run, jump, land with stick flipped back.
    tick(1)  # land_sel resolves with stick forward -> run
    check(wait_state("run", 30), "back to run after jump3 land")
    Input.action_press("jump", 1.0)
    player.tick()
    Input.action_release("jump")
    player.tick()
    check(state() == "jump1", "post-chain jump -> jump1 again")
    check(wait_state("land_sel", 200), "pivot setup jump lands -> land_sel")
    Input.action_release("ui_up")
    Input.action_press("ui_down", 1.0)  # stick [0, -1]: opposes facing + motion
    player.tick()
    check(state() == "pivot_moving", "stick back on landing -> pivot_moving (smo.pivot_moving_ok)")
    Input.action_release("ui_down")
