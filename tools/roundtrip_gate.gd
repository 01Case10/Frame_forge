extends SceneTree
## Round-trip gate (part 1 of 2): load every behavior JSON in
## rust/behaviors/ through the editor's BehaviorJSON and save it back to
## an output dir. Part 2 (tools/roundtrip_diff.py) proves the saved files
## are semantically identical to the originals under the Rust schema
## defaults — the editor must map 1:1 to the Rust pipeline, so any real
## difference fails the gate.
##
## Usage:
##   godot --headless --path . --script tools/roundtrip_gate.gd [-- --out DIR]
##   python3 tools/roundtrip_diff.py rust/behaviors DIR

func _init() -> void:
	var out_dir := "/tmp/ff_rt_out"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--out" and i + 1 < args.size():
			out_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(out_dir)
	var failures := 0
	var dir := DirAccess.open("res://rust/behaviors")
	if dir == null:
		print("RT-GATE: cannot open res://rust/behaviors")
		quit(1)
		return
	var names: Array = []
	for f in dir.get_files():
		if f.ends_with(".json"):
			names.append(f)
	names.sort()
	for name in names:
		var src: String = "res://rust/behaviors/" + String(name)
		var bh := BehaviorJSON.load_behavior(src)
		if bh == null:
			print("RT-GATE FAIL (load): ", name)
			failures += 1
			continue
		var err := BehaviorJSON.save_behavior(bh, out_dir + "/" + name)
		if err != OK:
			print("RT-GATE FAIL (save ", err, "): ", name)
			failures += 1
		else:
			print("RT-GATE wrote: ", name)
	print("RT-GATE: %d files, %d failures" % [names.size(), failures])
	quit(1 if failures > 0 else 0)
