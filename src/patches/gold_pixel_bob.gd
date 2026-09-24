extends "res://objects/gold/gold.gd"
# MiSTer patch for objects/gold/gold.gd (~30 coins active per tick).
# 1. Pixel-quantized bob: the bob is ~0.07 px per tick and the project snaps 2D
#    transforms to pixels, so write the node only when its rounded pixel
#    changes (same on-screen motion; pickup shape moves < 0.5 px).
# 2. Flattened: _physics_process inlines set_gold_position/rotation/visible
#    (3 script calls per coin per tick) and reads global_rotation once.
# 3. Typed method calls instead of property syntax (GDScript 4.3 compiles
#    `obj.prop` to a by-name lookup: ~1.5-2.6 us vs ~0.3-0.4 us, PLAN §6.10).
# Behaviour and order match the original _physics_process.

var _bob_y: float = NAN


func _physics_process(delta: float) -> void:
	if not visible_on_screen_enabler.is_on_screen():
		set_visible(false)
		return
	set_visible(true)
	if GameManager.game_state == GameManager.LEVEL_ACTIVE:
		var rot := get_global_rotation()
		if rot == 0:
			# set_gold_position
			var gp := get_global_position()
			if is_nan(_bob_y):
				_bob_y = gp.y
			_bob_y = move_toward(_bob_y, target_y, move_speed * delta)
			if _bob_y == target_y_high:
				target_y = target_y_low
			elif _bob_y == target_y_low:
				target_y = target_y_high
			var py := floorf(_bob_y + 0.5)
			if gp.y != py:
				set_global_position(Vector2(gp.x, py))
		else:
			# set_gold_rotation
			set_global_rotation(0.0)
		# set_gold_visible
		var hh: float = GameManager.happy_hour_timer
		if hh > 0:
			if hh < 1.2:
				var fs: bool = TimeManager.flash_short
				sprite.set_visible(fs)
				animated_sprite.set_visible(!fs)
		elif !sprite.is_visible() && !animated_sprite.is_visible():
			sprite.set_visible(true)
		if mega_gold:
			animated_sprite.play(&"active", 1.0, false)
	elif mega_gold:
		animated_sprite.pause()
		if get_global_rotation() != 0:
			set_global_rotation(0.0)


# Kept for anything else that calls it; the tick no longer does.
func set_gold_position(delta: float) -> void:
	if global_rotation != 0:
		return
	if is_nan(_bob_y):
		_bob_y = global_position.y
	_bob_y = move_toward(_bob_y, target_y, move_speed * delta)
	if _bob_y == target_y_high:
		target_y = target_y_low
	elif _bob_y == target_y_low:
		target_y = target_y_high
	var py := floorf(_bob_y + 0.5)
	if global_position.y != py:
		global_position.y = py
