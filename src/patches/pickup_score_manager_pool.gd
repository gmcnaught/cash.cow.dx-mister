extends "res://ui/pickup_score/pickup_score_manager.gd"
# MiSTer patch for ui/pickup_score/pickup_score_manager.gd: pools the "+N"
# popups instead of instantiate + add_child per pickup and queue_free per
# expiry (bursts of coin pickups; PackedScene.instantiate of a Label is the
# expensive part). Popups are created as before, so the loader still sees the
# original script path at node_added and applies both the pickup_score_pool.gd
# swap and the VISUAL_TICK adapter to them. A popup whose swap did not happen
# (MISTER_PATCHES_SKIP=pool_score) is not tracked and frees itself as before.
# Grow on demand (a spawn is never dropped); at most POOL_MAX parked popups are
# kept, extra ones free themselves. PREWARM popups are created when the level
# loads (a pool miss mid-play cost ~9 ms of physics: Label instantiate + theme
# resolution; PLAN §6.25). A pre-warmed popup skips its _ready initializer (the
# `_prewarming` flag below), so pre-warming consumes no randf_range and the global
# RNG sequence is unchanged; it gets the initializer on first use like any reuse.
# Reuse moves the popup to the last child so draw order stays newest-on-top.

const POOL_MAX := 16
const PREWARM := 8

var _free: Array = [] # Parked popups (pickup_score_pool.gd).
var _size0 := Vector2(-1.0, -1.0) # Scene size of a fresh popup (32x8).
var _prewarming := false # Read by pickup_score_pool.gd's _ready.


func _ready() -> void:
	super()
	_prewarming = true
	for i in PREWARM:
		var s: Label = pickup_score.instantiate()
		if _size0.x < 0.0:
			_size0 = s.get_size()
		add_child(s)
		if not s.has_method(&"_pool_reuse"):
			s.queue_free() # Swap did not happen (MISTER_PATCHES_SKIP=pool_score).
			break
		s._pool_owner = self
		s._pool_park()
		_free.push_back(s)
	_prewarming = false


func spawn_pickup_score(pickup_position: Vector2, pickup_value: int) -> void:
	var t: String = PLUS + str(pickup_value)
	while not _free.is_empty():
		var s = _free.pop_back()
		if not is_instance_valid(s):
			continue
		var score_r: Label = s
		score_r._pool_reuse(t, pickup_position, _size0)
		if score_r.get_index(false) != get_child_count(false) - 1:
			move_child(score_r, -1)
		return
	var score: Label = pickup_score.instantiate()
	if _size0.x < 0.0:
		_size0 = score.get_size()
	score.set_text(t)
	score.set_global_position(pickup_position, false)
	add_child(score)
	if score.has_method(&"_pool_reuse"):
		score._pool_owner = self


# Called by a popup at the end of its life. false = pool full, free it.
func _score_release(score: Node) -> bool:
	if _free.size() >= POOL_MAX:
		return false
	_free.push_back(score)
	return true
