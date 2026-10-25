extends Node

var player: BehaviorPlayer
var tick_count := 0

func _ready() -> void:
    player = BehaviorPlayer.new()
    player.behavior_path = "res://behaviors/smo_movement.json"
    player.auto_step = false
    player.position = Vector3(0, 5.0, 0)
    var col = CollisionShape3D.new()
    var capsule = CapsuleShape3D.new()
    capsule.radius = 0.4
    capsule.height = 1.8
    col.shape = capsule
    col.position = Vector3(0, 0.9, 0)
    player.add_child(col)
    add_child(player)

func _physics_process(_delta: float) -> void:
    # Don't tick the behavior, just do move_and_slide with gravity
    player.velocity = Vector3(0, -10, 0)
    player.move_and_slide()
    tick_count += 1
    if tick_count % 30 == 0:
        print("Tick ", tick_count, ": pos=", player.position, " floor=", player.is_on_floor())
    if tick_count >= 120:
        print("Collision test complete")
        get_tree().quit()
