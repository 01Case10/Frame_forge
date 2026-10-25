extends Node3D
## SMO Showcase — scripted choreography.

var player: BehaviorPlayer
var camera: Camera3D
var player_mesh: MeshInstance3D
var label: Label
var choreo := []
var choreo_idx := 0
var segment_tick := 0

func _ready() -> void:
    for a in ["jump", "crouch", "cap", "ui_left", "ui_right", "ui_up", "ui_down"]:
        if not InputMap.has_action(a):
            InputMap.add_action(a)
    
    camera = $Camera3D
    player_mesh = $PlayerMesh
    
    # UI
    var canvas = CanvasLayer.new()
    add_child(canvas)
    label = Label.new()
    label.add_theme_font_size_override("font_size", 48)
    label.position = Vector2(50, 50)
    canvas.add_child(label)
    
    # BehaviorPlayer
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
    if choreo_idx >= choreo.size():
        print("Showcase complete")
        get_tree().quit()
        return
    
    var seg = choreo[choreo_idx]
    if segment_tick == 0:
        label.text = seg[1]
        print("Segment: ", seg[1])
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
    
    # Update visual mesh and camera
    player_mesh.position = player.position + Vector3(0, 0.9, 0)
    var target = player.position + Vector3(0, 4, 8)
    camera.position = camera.position.lerp(target, 0.1)
    camera.look_at(player.position + Vector3(0, 1, 0))
    
    segment_tick += 1
    if segment_tick >= seg[0]:
        segment_tick = 0
        choreo_idx += 1
