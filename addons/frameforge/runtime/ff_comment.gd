class_name FFComment
extends Resource
## Editor-only: a comment frame on a sub-machine graph canvas.
## Organizational only; zero runtime effect.

@export var title: String = "Comment"
@export var position := Vector2.ZERO
@export var size := Vector2(280, 160)
@export var tint := Color(0.9, 0.8, 0.4, 1.0)
