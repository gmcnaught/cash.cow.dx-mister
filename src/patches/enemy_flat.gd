extends "res://enemies/enemies_generic/enemy.gd"
# MiSTer patch for enemies/enemies_generic/enemy.gd: the tick's helper calls
# (set_move_speed, track_hard_limits, track_enemy_hud_warning,
# set_shader_material) inlined; the idle animation and the flash shader
# moved to _process (visual only). Same order and reads: player_health_state is
# read after the state machine runs, as the original does (a collision during
# that step can change it). Typed method calls instead of property syntax
# (PLAN §6.10); the flash-shader parameter is written only when it changes
# (only this code writes it).


var _opacity := -1 # Last value written; -1 forces the first write.
var _shader: ShaderMaterial


func _physics_process(delta: float) -> void:
	if GameManager.game_state == GameManager.LEVEL_ACTIVE:
		state_machine.check_for_new_state(delta)
		# set_move_speed
		if GameManager.player_health_state == GameManager.PLAYER_PICKAXE:
			move_speed = flee_move_speed
		else:
			move_speed = normal_move_speed
		# track_hard_limits
		if hard_limits:
			var x := get_global_position().x
			if x < hard_limit_left && hard_limit_left != 0:
				set_direction(1)
			elif x > hard_limit_right && hard_limit_right != 0:
				set_direction(-1)
		# track_enemy_hud_warning (the common case is the timer check)
		track_enemy_timer -= delta
		if track_enemy_timer <= 0 && !on_screen:
			var gp := get_global_position()
			var ex := gp.x
			var px: float = GlobalVariables.PlayerPosition.x
			if not (px < ex && direction > 0) and not (px > ex && direction < 0):
				var dx := absf(ex - px)
				if dx <= TRACK_ENEMY_X_DISTANCE and dx >= TRACK_ENEMY_MIN_X_DISTANCE:
					track_enemy_timer = TRACK_ENEMY_INTERVAL
					var warning_position_x: int = 1
					if ex < px:
						warning_position_x = -1
					Signals.emit_spawn_enemy_hud_warning(self, enemy_id, warning_position_x, int(gp.y), enemy_color)


# Visual part of the original tick, once per rendered frame (catch-up frames
# run physics up to 8 times).
func _process(_delta: float) -> void:
	if GameManager.game_state != GameManager.LEVEL_ACTIVE:
		animated_sprite.play(&"idle", 1.0, false)
	# set_shader_material
	var op := 0
	if GameManager.player_health_state == GameManager.PLAYER_PICKAXE:
		var t: float = GameManager.player_pickaxe_timer
		if (t > 1 && TimeManager.flash_medium) or (t <= 1 && TimeManager.flash_short):
			op = 1
	if op != _opacity:
		_opacity = op
		if _shader == null:
			_shader = enemy_white_shader as ShaderMaterial
		_shader.set_shader_parameter(&"opacity", op)
