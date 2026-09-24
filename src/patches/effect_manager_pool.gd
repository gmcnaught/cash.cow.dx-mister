extends "res://objects/effect/effect_manager.gd"
# MiSTer patch for objects/effect/effect_manager.gd: pools the one-shot
# AnimatedSprite2D effects (walk dust every step, jump/slide/drop dust, coin
# pickup sparkles) instead of instantiate + add_child per spawn and
# queue_free per finish. One pool per PackedScene; grow on demand (a spawn is
# never dropped); at most POOL_MAX parked nodes per scene, extra ones free
# themselves. A few nodes of the frequent scenes are pre-warmed in _ready.
# Effects are created as before, so the loader sees the original script path
# at node_added and swaps in effect_pool.gd / effect_delete_pool.gd; a node
# whose swap did not happen (MISTER_PATCHES_SKIP=pool_fx) is not tracked and
# frees itself as before, and pre-warming stops.
# Reuse sets what the spawn function sets on a fresh instance before add_child:
# `global_position = p` and `global_scale.x = d` with no parent are
# position = p and scale = (d, 1) (the scenes have scale 1), flip_h for the
# bonus-enter effect; then the node restores its scene state and autoplays.
# It is moved to the last child so draw order stays newest-on-top.
# Left on the original path (not "play once, then free"):
#  - spawn_warning_sign_effect: danger_warning_sign.gd, 0.5 s timer + flash.
#  - spawn_eye_effect: eye_effect.gd, @onready initial_x, sine path, frees
#    when off the top.
#  - spawn_death_effect: enemy_death_effect.gd, reads PlayerDirection and the
#    flash phase in _ready, falls under gravity.
# These are infrequent (enemy events), and their state lives in _ready /
# @onready code that would need re-running.

const POOL_MAX := 12

var _pools := {} # PackedScene -> Array of parked effects.
var _s0 := {} # PackedScene -> fresh-instance state (see _fx_new).
var _hooked := true # false once a new effect came back without the pool script.


func _ready() -> void:
	super()
	for scene: PackedScene in [gold_pickup_effect, mega_gold_pickup_effect, bonus_pickup_effect,
			bonus_enter_effect, jump_effect_directional, jump_effect_static, slide_effect,
			slide_start_effect, drop_effect, walk_effect, pickaxe_end_effect,
			stage_clear_effect, loudspeaker_kill_effect]:
		_pools[scene] = []
	_prewarm(walk_effect, 3)
	_prewarm(gold_pickup_effect, 6)
	_prewarm(mega_gold_pickup_effect, 3)
	_prewarm(jump_effect_directional, 2)
	_prewarm(jump_effect_static, 2)
	_prewarm(drop_effect, 2)
	_prewarm(slide_effect, 1)
	_prewarm(slide_start_effect, 1)


func _prewarm(scene: PackedScene, count: int) -> void:
	for i in count:
		if not _hooked:
			return
		var e := _fx_new(scene)
		e.set_visible(false) # _fx_new captured the scene value first.
		_fx_add(e, scene)
		if not _hooked:
			e.queue_free() # Original script: would play once at the origin.
			return
		e._pool_park()
		_pools[scene].push_back(e)


# A parked effect of `scene`, or null.
func _fx_take(scene: PackedScene) -> AnimatedSprite2D:
	var a: Array = _pools[scene]
	while not a.is_empty():
		var e = a.pop_back()
		if is_instance_valid(e):
			return e
	return null


func _fx_new(scene: PackedScene) -> AnimatedSprite2D:
	var e: AnimatedSprite2D = scene.instantiate()
	if not _s0.has(scene):
		# Scene state of a fresh instance (before _ready), restored on reuse.
		_s0[scene] = [e.get_animation(), StringName(e.get_autoplay()), e.get_frame(),
				e.get_frame_progress(), e.is_flipped_h(), e.is_visible()]
	return e


func _fx_add(e: AnimatedSprite2D, scene: PackedScene) -> void:
	add_child(e)
	if e.has_method(&"_pool_reuse"):
		var s0: Array = _s0[scene]
		e._pool_init(self, scene, s0[0], s0[1], s0[2], s0[3], s0[4], s0[5])
	else:
		_hooked = false


func _fx_restart(e: AnimatedSprite2D) -> void:
	e._pool_reuse()
	if e.get_index(false) != get_child_count(false) - 1:
		move_child(e, -1)


# Called by an effect when its animation finishes. false = pool full, free it.
func _fx_release(e: Node, scene: PackedScene) -> bool:
	var a: Array = _pools[scene]
	if a.size() >= POOL_MAX:
		return false
	a.push_back(e)
	return true


# --- spawn functions: reuse path, else the original code + _fx_add ---

func _spawn_at(scene: PackedScene, effect_position: Vector2) -> void:
	var e := _fx_take(scene)
	if e != null:
		e.set_position(effect_position)
		_fx_restart(e)
		return
	e = _fx_new(scene)
	e.global_position = effect_position
	_fx_add(e, scene)


func _spawn_dir(scene: PackedScene, effect_position: Vector2, effect_direction: int) -> void:
	var e := _fx_take(scene)
	if e != null:
		e.set_position(effect_position)
		e.set_scale(Vector2(effect_direction, 1.0))
		_fx_restart(e)
		return
	e = _fx_new(scene)
	e.global_position = effect_position
	e.global_scale.x = effect_direction
	_fx_add(e, scene)


func spawn_gold_pickup_effect(effect_position: Vector2) -> void:
	_spawn_at(gold_pickup_effect, effect_position)


func spawn_mega_gold_pickup_effect(effect_position: Vector2) -> void:
	_spawn_at(mega_gold_pickup_effect, effect_position)


func spawn_bonus_pickup_effect(effect_position: Vector2) -> void:
	_spawn_at(bonus_pickup_effect, effect_position)


func spawn_bonus_enter_effect() -> void:
	var p: Vector2 = GlobalVariables.PlayerBonusExitPosition + Vector2(0, -32)
	var flip: bool = GlobalVariables.PlayerBonusExitDirection == -1
	var e := _fx_take(bonus_enter_effect)
	if e != null:
		e.set_position(p)
		if flip:
			e.set_flip_h(true)
		else:
			e.set_flip_h(e._flip0)
		_fx_restart(e)
		return
	e = _fx_new(bonus_enter_effect)
	e.global_position = p
	if flip:
		e.flip_h = true
	_fx_add(e, bonus_enter_effect)


func spawn_jump_effect_directional(effect_position: Vector2, effect_direction: int) -> void:
	_spawn_dir(jump_effect_directional, effect_position, effect_direction)


func spawn_jump_effect_static(effect_position: Vector2) -> void:
	_spawn_at(jump_effect_static, effect_position)


func spawn_slide_effect(effect_position: Vector2, effect_direction: int) -> void:
	_spawn_dir(slide_effect, effect_position, effect_direction)


func spawn_slide_start_effect(effect_position: Vector2, effect_direction: int) -> void:
	_spawn_dir(slide_start_effect, effect_position, effect_direction)


func spawn_drop_effect(effect_position: Vector2) -> void:
	_spawn_at(drop_effect, effect_position)


func spawn_walk_effect(effect_position: Vector2, effect_direction: int) -> void:
	_spawn_dir(walk_effect, effect_position, effect_direction)


func spawn_pickaxe_end_effect(effect_position: Vector2) -> void:
	_spawn_at(pickaxe_end_effect, effect_position)


func spawn_stage_clear_effect(effect_position: Vector2) -> void:
	_spawn_at(stage_clear_effect, effect_position)


func spawn_loudspeaker_kill_effect(effect_position: Vector2, effect_direction: int) -> void:
	_spawn_dir(loudspeaker_kill_effect, effect_position, effect_direction)
