extends Node
func _ready() -> void:
    var text := FileAccess.get_file_as_string("res://oracles/backflip.csv").replace("\r", "")
    var lines := text.split("\n")
    var header := lines[0].split(",")
    print("bt index: ", header.find("buttons"), " header: ", header)
    var f := lines[1].split(",")
    print("f size: ", f.size(), " f[5]: '", f[5], "'")
    get_tree().quit()
