extends "res://player/player_detectors.gd"
# MiSTer patch for player/player_detectors.gd: the tick's 7 helper calls
# inlined, in the same order with the same reads and writes.
# health_collider.disabled is written only when it changes (the original wrote
# it every tick; each write pushed a shape update to the physics server).
# Native properties via typed method calls (PLAN §6.10). rainbow_detector (a
# ShapeCast2D) is never read anywhere in the game, so it is disabled (§6.15).


func _ready() -> void:
	super()
	# Never read by any script (only declared): stop sweeping it every tick.
	rainbow_detector.set_enabled(false)


func _physics_process(_delta: float) -> void:
	var p := player
	var gs: int = GameManager.game_state
	var hs: int = GameManager.player_health_state

	# health_check
	var hurtable: bool = GameManager.player_state == GameManager.PLAYER_ACTIVE && hs == GameManager.PLAYER_VULNERABLE
	if health_collider.is_disabled() == hurtable:
		health_collider.set_disabled(!hurtable)

	# slide_check
	if slide_detector.is_colliding():
		if !p.on_slide && p.get_velocity().y > 0:
			var slide: Area2D = slide_detector.get_collider(0)
			p.slide_position = slide.get_global_position()
			if slide.slide_target_position == p.slide_target_position && p.slide_timer > 0:
				p.on_slide = false
			else:
				p.slide_target_position = slide.slide_target_position
				p.on_slide = true
	else:
		p.on_slide = false

	# ground_check
	p.can_spawn_rainbow = !ground_detector.is_colliding()

	# conveyor_check (its LEVEL_END early return only skips this check)
	if gs == GameManager.LEVEL_END:
		p.on_conveyor = false
	elif conveyor_detector.is_colliding():
		if !p.on_conveyor:
			var conveyor: Area2D = conveyor_detector.get_collider(0)
			p.conveyor_direction = conveyor.conveyor_direction
			p.on_conveyor = true
	else:
		p.on_conveyor = false

	# wall_check
	p.on_wall_left = wall_detector_left.is_colliding()
	p.on_wall_right = wall_detector_right.is_colliding()

	# boat_check
	if boat_detector.is_colliding() && p.get_velocity().y >= 0:
		p.apply_floor_snap()

	# trap_check
	p.on_trap = trap_detector.is_colliding() && (hs == GameManager.PLAYER_PICKAXE or hs == GameManager.PLAYER_INVINCIBLE)
