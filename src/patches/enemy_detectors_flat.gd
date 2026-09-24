extends "res://enemies/enemies_generic/enemy_detectors.gd"
# MiSTer patch for enemies/enemies_generic/enemy_detectors.gd: the original
# tick makes 7 script calls and reads `owner` (get_owner()) and
# owner.direction ~20 times. Same checks, same order, same writes, with owner
# and direction read once. gap_check's quirk (the gap flags are only cleared
# when neither side has a gap) is kept. slide_detector_left/_right are never
# read anywhere in the game, so they are disabled (PLAN §6.15).


func _ready() -> void:
	# Never read by any script (only declared): stop casting them every tick.
	slide_detector_left.set_enabled(false)
	slide_detector_right.set_enabled(false)


func _physics_process(_delta: float) -> void:
	if GameManager.game_state == GameManager.LEVEL_END:
		return
	var o := owner
	var dir: float = o.direction

	# trap_check
	o.on_trap = trap_detector.is_colliding()
	if dir < 0 && trap_detector_left.is_colliding():
		o.at_trap = true
	elif dir > 0 && trap_detector_right.is_colliding():
		o.at_trap = true
	else:
		o.at_trap = false

	# wall_check
	if dir < 0 && wall_detector_left.is_colliding():
		o.at_wall = true
	elif dir > 0 && wall_detector_right.is_colliding():
		o.at_wall = true
	else:
		o.at_wall = false

	# gap_check
	if dir < 0 && !ground_detector_left.is_colliding():
		if !ground_detector_far_left.is_colliding():
			o.at_large_gap = true
		else:
			o.at_small_gap = true
	elif dir > 0 && !ground_detector_right.is_colliding():
		if !ground_detector_far_right.is_colliding():
			o.at_large_gap = true
		else:
			o.at_small_gap = true
	else:
		o.at_small_gap = false
		o.at_large_gap = false

	# slide_check
	if slide_detector.is_colliding():
		var slide: Area2D = slide_detector.get_collider()
		o.slide_position = slide.get_global_position()
		o.slide_target_position = slide.slide_target_position
		o.on_slide = true
	else:
		o.on_slide = false

	# conveyor_check
	if conveyor_detector.is_colliding():
		var conveyor: Area2D = conveyor_detector.get_collider()
		o.conveyor_direction = conveyor.conveyor_direction
		o.on_conveyor = true
	else:
		o.on_conveyor = false

	# trampoline_check
	if trampoline_detector.is_colliding():
		o.active_trampoline = trampoline_detector.get_collider()
		o.on_trampoline = true
	else:
		o.on_trampoline = false

	# boat_check
	o.on_boat = boat_detector.is_colliding()
