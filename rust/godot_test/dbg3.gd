extends Node
func _ready() -> void:
    for a in ["ff_left", "ff_right", "ff_fwd", "ff_back"]:
        if not InputMap.has_action(a):
            InputMap.add_action(a)
    await get_tree().process_frame
    var player = BehaviorPlayer.new()
    player.auto_step = false
    add_child(player)
    print("loading...")
    var ok = player.load_behavior("res://behaviors/backflip_chain.json")
    print("load ok: ", ok, " state: ", player.current_state_name("Baked"))
    get_tree().quit()
