extends Node
func _ready() -> void:
    var text := FileAccess.get_file_as_string("res://oracles/backflip.csv")
    print("text len: ", text.length())
    var lines := text.split("\n")
    print("lines: ", lines.size())
    print("line0: '", lines[0], "'")
    var header := lines[0].split(",")
    print("header size: ", header.size(), " find pos_x: ", header.find("pos_x"))
    get_tree().quit()
