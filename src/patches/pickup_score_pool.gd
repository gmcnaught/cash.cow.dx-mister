extends "res://ui/pickup_score/pickup_score.gd"
# MiSTer patch for ui/pickup_score/pickup_score.gd (the "+N" popup; one per
# coin/extra/enemy pickup). Pooled by pickup_score_manager_pool.gd: at the end
# of its life the popup parks itself (hidden, PROCESS_MODE_DISABLED so
# can_process() is false for the loader's VISUAL_TICK and for its own physics
# callback) instead of queue_free(); the manager resets and reuses it.
# Without that manager (_pool_owner == null) or with its pool full it frees
# itself as the original does.
# The tick is flattened with typed calls (PLAN §6.10). switch_color() re-added
# the same yellow override every tick once speed < 24; each add re-themes the
# Label (NOTIFICATION_THEME_CHANGED). It is added once here: same colour.
# Order and arithmetic of the tick match the original.

var _pool_owner: Node = null # pickup_score_manager_pool.gd, set after add_child.
var _speed0: float = 92.0 # Script default of `speed`, captured in _ready.
var _mode0: ProcessMode = PROCESS_MODE_INHERIT # Scene value, captured in _ready.
var _yellow := false # font_color override present.


func _ready() -> void:
	_speed0 = speed # Before initialize_score() scales it.
	_mode0 = get_process_mode()
	var p := get_parent()
	if p != null and p.get(&"_prewarming") == true:
		return # Pre-warmed and parked by the manager: no initializer, no randf_range.
	super()


func _physics_process(delta: float) -> void:
	# move_score_up
	var gp := get_global_position()
	gp.y -= speed * delta
	set_global_position(gp, false)
	speed -= DECELERATION * delta
	# switch_color
	if speed < 24 and not _yellow:
		_yellow = true
		add_theme_color_override(&"font_color", Color.YELLOW)
	# flash_score
	if speed < -40:
		var fs: bool = TimeManager.flash_short
		set_visible(fs)
	# delete_score
	if speed < -120:
		_pool_release()


func delete_score() -> void:
	if speed < -120:
		_pool_release()


func _pool_release() -> void:
	if _pool_owner != null and _pool_owner._score_release(self):
		_pool_park()
		return
	queue_free()


func _pool_park() -> void:
	set_visible(false)
	set_process_mode(PROCESS_MODE_DISABLED)


# Called by the manager instead of instantiate + add_child. Resets what a fresh
# instance has (script defaults, no font_color override, scene size), applies
# what spawn_pickup_score sets (text; global_position assigned before
# add_child = local position), then runs the original _ready initializer
# (visible, -8/-16 offset, randomized speed: one randf_range per spawn, as the
# original).
func _pool_reuse(p_text: String, p_position: Vector2, p_size: Vector2) -> void:
	speed = _speed0
	color_cycle_timer = COLOR_CYLCE_INTERVAL
	color_cycle_index = 0
	if _yellow:
		_yellow = false
		remove_theme_color_override(&"font_color")
	set_text(p_text)
	set_size(p_size)
	set_position(p_position, false)
	set_process_mode(_mode0)
	initialize_score()
