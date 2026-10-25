extends Node
## Headless state-trace capture for the SMO showcase choreography.
## Replicates smo_showcase.gd's choreography exactly, but logs per-tick
## CSV (tick, segment, nerves_state, cap_state, pos) to trace_capture.csv
## instead of rendering 3D. Temporary research file for the 2D trace video.

var player: BehaviorPlayer
var choreo := []
var choreo_idx := 0
var segment_tick := 0
var tick := 0
var tick_count := 0
var log_lines := []
var phase := 0

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
    build_choreo()
    player.velocity = Vector3.ZERO
    player.move_and_slide()

func build_choreo() -> void:
    # Identical choreography to smo_showcase.gd
    choreo = [
        [120, "Idle", {}, [0, 0]],
        [180, "Run", {}, [0, 1]],
        [60, "Brake Stop", {}, [0, 0]],
        [120, "Run", {}, [0, 1]],
        [60, "Pivot", {}, [0, -1]],
        [120, "Run", {}, [0, 1]],
        [30, "Jump 1", {"jump": true}, [0, 1]],
        [60, "Jump 1 (air)", {}, [0, 1]],
        [30, "Jump 2", {"jump": true}, [0, 1]],
        [60, "Jump 2 (air)", {}, [0, 1]],
        [30, "Jump 3", {"jump": true}, [0, 1]],
        [90, "Triple Jump", {}, [0, 1]],
        [60, "Land", {}, [0, 0]],
        [60, "Crouch", {"crouch": true}, [0, 1]],
        [90, "Roll", {"crouch": true, "cap": true}, [0, 1]],
        [30, "Long Jump!", {"jump": true}, [0, 1]],
        [90, "Long Jump", {}, [0, 1]],
        [60, "Land", {}, [0, 0]],
        [30, "Jump", {"jump": true}, [0, 1]],
        [15, "Ground Pound!", {"jump": true, "crouch": true}, [0, 1]],
        [25, "Dive!", {"cap": true}, [0, 1]],
        [70, "Dive", {}, [0, 1]],
        [60, "Land", {}, [0, 0]],
        [60, "Idle", {}, [0, 0]],
        [30, "Cap Throw!", {"cap": true}, [0, 0]],
        [120, "Cap Flying", {}, [0, 0]],
        [60, "Idle", {}, [0, 0]],
        [120, "Done!", {}, [0, 0]],
    ]

func _physics_process(_delta: float) -> void:
    if phase == 0:
        # Wait for behavior to load, then settle: tick with no input until
        # grounded (contact.ground needs a real move_and_slide first).
        if player.current_state_name("Nerves") != "<none>":
            player.velocity = Vector3.ZERO
            player.move_and_slide()
            phase = 1
            tick_count = 0
        return
    if phase == 1:
        # Settle ticks: let the body land and the behavior reach idle.
        player.tick()
        tick_count += 1
        if tick_count >= 30 and player.current_state_name("Nerves") == "idle":
            phase = 2
        elif tick_count >= 120:
            # Fallback: start anyway, log where we are.
            print("Settle fallback, state=", player.current_state_name("Nerves"))
            phase = 2
        return
    if choreo_idx >= choreo.size():
        var f = FileAccess.open("res://trace_capture.csv", FileAccess.WRITE)
        for l in log_lines:
            f.store_line(l)
        f.close()
        print("Trace capture complete: ", log_lines.size(), " ticks")
        get_tree().quit()
        return

    var seg = choreo[choreo_idx]
    if segment_tick == 0:
        for a in ["jump", "crouch", "cap", "ui_up", "ui_down", "ui_left", "ui_right"]:
            Input.action_release(a)

    var actions = seg[2]
    var stick = seg[3]
    for a in actions.keys():
        if actions[a]:
            Input.action_press(a, 1.0)

    if stick[1] > 0.1:
        Input.action_press("ui_up", stick[1])
    elif stick[1] < -0.1:
        Input.action_press("ui_down", -stick[1])
    if stick[0] > 0.1:
        Input.action_press("ui_right", stick[0])
    elif stick[0] < -0.1:
        Input.action_press("ui_left", -stick[0])

    player.tick()
    tick += 1
    var p = player.position
    log_lines.append("%d|%s|%s|%s|%.3f|%.3f|%.3f" % [tick, seg[1], player.current_state_name("Nerves"), player.current_state_name("Cap"), p.x, p.y, p.z])

    segment_tick += 1
    if segment_tick >= seg[0]:
        segment_tick = 0
        choreo_idx += 1
