extends Node

func _ready() -> void:
    for a in ["ff_left", "ff_right", "ff_fwd", "ff_back"]:
        if not InputMap.has_action(a):
            InputMap.add_action(a)
    var player = BehaviorPlayer.new()
    player.behavior_path = "res://walk.json"
    player.auto_step = false
    add_child(player)
    # load happens in _ready; defer test to next frame
    await get_tree().process_frame
    run_test(player)
    get_tree().quit()

func run_test(player: BehaviorPlayer) -> void:
    if player.tick_count() == 0 and player.current_state_name("Locomotion") == "<none>":
        print("FAIL: behavior not loaded")
        return
    Input.action_press("ff_back", 1.0)
    for i in 60:
        player.tick()
    Input.action_release("ff_back")
    var pos = player.position
    print("pos after 60 ticks: ", pos)
    # walk.json WalkAccel: expect forward (+Z) motion, z > 5
    if pos.z > 5.0 and absf(pos.x) < 0.01:
        print("PASS: GDExtension BehaviorPlayer moves")
    else:
        print("FAIL: unexpected pos ", pos)
