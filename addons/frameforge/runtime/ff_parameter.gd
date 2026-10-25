class_name FFParameter
extends Resource
## A designer-declared typed blackboard parameter on a FrameBehavior.
## Game code writes values at runtime via BehaviorPlayer.set_param().

enum PType { BOOL, INT, FLOAT, STRING }

@export var name: String = ""
@export var ptype: int = PType.FLOAT
@export var default_value: Variant = 0.0
