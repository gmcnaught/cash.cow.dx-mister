extends Node
# Frame-spike logger (measurement only; load via override.cfg). Prints one
# SPIKE line for every frame whose wall period exceeds SPIKE_MS or that ran
# 2+ physics ticks, with what happened in it: nodes added/removed, scene
# files instantiated, game/player state. Runs last in the frame (priority).

const SPIKE_MS := 20.0
var _last_us := 0
var _last_phys := 0
var _added := 0
var _removed := 0
var _scenes := {}
var _n_spikes := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 100000
	get_tree().node_added.connect(_on_added)
	get_tree().node_removed.connect(_on_removed)
	_last_us = Time.get_ticks_usec()
	_last_phys = Engine.get_physics_frames()


func _on_added(n: Node) -> void:
	_added += 1
	if n.scene_file_path != "":
		var k := n.scene_file_path.get_file()
		_scenes[k] = _scenes.get(k, 0) + 1


func _on_removed(_n: Node) -> void:
	_removed += 1


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := (now - _last_us) / 1000.0
	var phys := Engine.get_physics_frames()
	var ticks := phys - _last_phys
	if dt > SPIKE_MS or ticks >= 2:
		_n_spikes += 1
		var gm = get_node_or_null("/root/GameManager")
		var st := ""
		if gm != null:
			st = "gs=%s ps=%s hs=%s" % [gm.game_state, gm.player_state, gm.player_health_state]
		print("SPIKE t=%.2f dt=%.1fms ticks=%d added=%d removed=%d nodes=%d %s scenes=%s" % [
			now / 1e6, dt, ticks, _added, _removed, get_tree().get_node_count(), st, _scenes])
	_added = 0
	_removed = 0
	if not _scenes.is_empty():
		_scenes = {}
	_last_us = now
	_last_phys = phys
