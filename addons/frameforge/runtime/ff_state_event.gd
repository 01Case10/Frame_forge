class_name FFStateEvent
extends Resource
## A custom named event authored on a FrameState.
## (Runtime emission + event_fired signal: phase 3.)

enum Trigger { ON_ENTER, ON_EXIT, ON_FRAME }

@export var event_name: String = ""
@export var trigger: int = Trigger.ON_ENTER
@export var frame: int = 0
