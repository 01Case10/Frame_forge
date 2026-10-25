extends Node
## Phase 6 gate: run the 14 differentials through the Rust GDExtension
## BehaviorPlayer in headless Godot. Mirrors exit_gate/run_gate.gd.

var _passes := 0
var _fails := 0

func _ready() -> void:
    for a in ["ff_left", "ff_right", "ff_fwd", "ff_back", "ff_jump", "ff_attack", "ff_crouch"]:
        if not InputMap.has_action(a):
            InputMap.add_action(a)
    await get_tree().process_frame
    var cases = [
        ["walk.json", "walk_straight.csv", 1, "walk_straight"],
        ["walk.json", "walk_release.csv", 1, "walk_release"],
        ["walk.json", "walk_turn.csv", 1, "walk_turn"],
        ["move.json", "jump_neutral.csv", 1, "jump_neutral_tap"],
        ["move.json", "jump_neutral_held.csv", 1, "jump_neutral_held"],
        ["jump_fwd.json", "jump_forward_held.csv", 1, "jump_forward"],
        ["double_jump.json", "double_jump.csv", 1, "double_jump"],
        ["ground_pound.json", "ground_pound.csv", 1, "ground_pound"],
        ["long_jump.json", "long_jump.csv", 1, "long_jump_hand"],
        ["backflip_chain.json", "backflip.csv", 2, "backflip"],
        ["wall_kick_chain.json", "wall_kick.csv", 2, "wall_kick"],
        ["long_jump_chain.json", "long_jump.csv", 2, "long_jump_baked"],
        ["walk_chain.json", "walk_forward_90f.csv", 2, "walk_chain"],
        ["triple_jump_baked.json", "triple_jump.csv", 2, "triple_jump"],
    ]
    for c in cases:
        run_one(c[0], c[1], c[2], c[3])
    print("==== GDExtension gate: %d PASS, %d FAIL ====" % [_passes, _fails])
    get_tree().quit(_fails)

func run_one(behavior: String, oracle: String, tpf: int, label: String) -> void:
    var player = BehaviorPlayer.new()
    player.auto_step = false
    add_child(player)
    if not player.load_behavior("res://behaviors/" + behavior):
        print("FAIL ", label, ": load failed")
        _fails += 1
        player.queue_free()
        return
    var data = load_oracle("res://oracles/" + oracle)
    var positions: Array = data[0]
    var inputs: Array = data[1]
    var pos: Vector3 = positions[0]
    player.position = pos
    var samples: Array = [pos]
    var total_ticks := (positions.size() - 1) * tpf
    for tick_idx in total_ticks:
        var fi: int = mini(tick_idx / tpf, inputs.size() - 1)
        replay_input(inputs[fi])
        player.tick()
        pos = player.position
        if (tick_idx + 1) % tpf == 0:
            samples.append(pos)
    player.queue_free()
    # Compare (positions in meters; oracle cm * 0.01).
    var n: int = mini(samples.size(), positions.size())
    var mean := 0.0
    var mx := 0.0
    for k in n:
        var e: float = samples[k].distance_to(positions[k]) * 100.0
        mean += e
        mx = maxf(mx, e)
    mean /= n
    var final_err: float = samples[n - 1].distance_to(positions[n - 1]) * 100.0
    var passed: bool = mean < 0.5 and mx < 2.0 and final_err < 1.0
    print("==== %s: frames=%d mean=%.4fcm max=%.4fcm final=%.4fcm -> %s ====" % [
        label, n, mean, mx, final_err, "PASS" if passed else "FAIL"])
    if passed:
        _passes += 1
    else:
        _fails += 1

func load_oracle(path: String) -> Array:
    var text := FileAccess.get_file_as_string(path).replace("\r", "")
    var lines := text.split("\n")
    var header := lines[0].split(",")
    var ix := header.find("pos_x")
    var iy := header.find("pos_y")
    var iz := header.find("pos_z")
    var sx := header.find("stick_x")
    var sy := header.find("stick_y")
    var bt := header.find("buttons")
    var positions := []
    var inputs := []
    for i in range(1, lines.size()):
        var f := lines[i].split(",")
        if f.size() <= maxi(maxi(ix, iy), maxi(maxi(iz, sx), maxi(sy, bt))):
            continue
        positions.append(Vector3(
            f[ix].to_float() * 0.01, f[iy].to_float() * 0.01, f[iz].to_float() * 0.01))
        inputs.append([f[sx].to_float(), f[sy].to_float(), f[bt].to_int()])
    return [positions, inputs]

func replay_input(inp: Array) -> void:
    var sx: float = inp[0]
    var sy: float = inp[1]
    var buttons: int = inp[2]
    set_axis("ff_right", "ff_left", sx / 80.0)
    set_axis("ff_fwd", "ff_back", sy / 80.0)
    set_button("ff_jump", buttons & 0x1)
    set_button("ff_attack", buttons & 0x2)
    set_button("ff_crouch", buttons & 0x4)

func set_axis(neg: String, pos: String, v: float) -> void:
    if v > 0.05:
        Input.action_release(neg)
        Input.action_press(pos, clampf(v, 0.0, 1.0))
    elif v < -0.05:
        Input.action_release(pos)
        Input.action_press(neg, clampf(-v, 0.0, 1.0))
    else:
        Input.action_release(neg)
        Input.action_release(pos)

func set_button(action: String, mask: int) -> void:
    if mask != 0:
        Input.action_press(action)
    else:
        Input.action_release(action)
