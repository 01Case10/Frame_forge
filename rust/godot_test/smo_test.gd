extends Node

var player: BehaviorPlayer
var tick_count := 0
var phase := 0

func _ready() -> void:
    for a in ["jump", "crouch", "cap", "ui_left", "ui_right", "ui_up", "ui_down"]:
        if not InputMap.has_action(a):
            InputMap.add_action(a)
    player = BehaviorPlayer.new()
    player.behavior_path = "res://behaviors/smo_movement.json"
    player.auto_step = false
    player.position = Vector3(0, 0.0, 0)
    var col = CollisionShape3D.new()
    var capsule = CapsuleShape3D.new()
    capsule.radius = 0.4
    capsule.height = 1.8
    col.shape = capsule
    col.position = Vector3(0, 0.9, 0)
    player.add_child(col)
    add_child(player)

func _physics_process(_delta: float) -> void:
    if phase == 0:
        # Wait for behavior to load
        if player.current_state_name("Nerves") != "<none>":
            print("PASS: SMO loaded, state: ", player.current_state_name("Nerves"))
            # Settle physics: do a move_and_slide to establish floor contact
            player.velocity = Vector3.ZERO
            player.move_and_slide()
            print("After physics settle: floor=", player.is_on_floor())
            phase = 1
            tick_count = 0
    elif phase == 1:
        # Settle on floor
        player.tick()
        tick_count += 1
        if tick_count >= 10:
            print("After settle: ", player.current_state_name("Nerves"), " pos=", player.position)
            phase = 2
            tick_count = 0
            Input.action_press("ui_up", 1.0)
    elif phase == 2:
        # Run with stick
        player.tick()
        tick_count += 1
        if tick_count >= 30:
            var state = player.current_state_name("Nerves")
            print("After 30 ticks: ", state, " pos=", player.position)
            if state == "run":
                print("PASS: idle -> run in Godot")
            else:
                print("FAIL: expected run, got ", state)
            Input.action_release("ui_up")
            phase = 3
    elif phase == 3:
        print("SMO Godot test complete")
        get_tree().quit()
