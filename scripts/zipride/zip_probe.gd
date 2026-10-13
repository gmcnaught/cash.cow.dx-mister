extends Node
# Measurement only (autoload via scripts/zipride/run.sh; never shipped).
# Reproduces the stage 5 boss zipwire rides through the two mega gold lines
# (level_05.tscn mega_gold_7..21 under zipwire_rig_left, 22..33 under
# zipwire_rig_right): loads stage 5, waits for play, puts the player on a
# zipwire and logs every frame of the ride. Stage 5 is reloaded before each
# ride, so every ride starts on freshly built (pre-warmed only) pools, as the
# first ride after a level load does in play.
# Output (ZIPPROBE_OUT, default /tmp/cc_zip.txt): one F line per frame
# (ride, frame, wall us since the last frame, physics ticks run, on_zipwire,
# gold collected, scenes instantiated in it) and one R line per ride.

const RIDES := 6
const WIRES := ["zipwire_rig_left", "zipwire_rig_right"]
const SETTLE_FRAMES := 90 # Active play before the ride.
const TAIL_FRAMES := 90 # After the eject: popups and sparkles end.

var _out: FileAccess
var _phase := "boot"
var _ride := 0
var _n := 0
var _last_us := 0
var _last_phys := 0
var _added := {}
var _rows: Array = []
var _was_on := false
var _off_frames := 0
var _gold0 := 0
var _load_max_us := 0
var _player: Node = null
var _golds: Array[Node] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 100000 # Last in the frame.
	var path := OS.get_environment("ZIPPROBE_OUT")
	_out = FileAccess.open(path if path != "" else "/tmp/cc_zip.txt", FileAccess.WRITE)
	get_tree().node_added.connect(_on_added)
	_last_us = Time.get_ticks_usec()
	_last_phys = Engine.get_physics_frames()


func _on_added(n: Node) -> void:
	if n.scene_file_path != "":
		var k := n.scene_file_path.get_file().get_basename()
		_added[k] = _added.get(k, 0) + 1


func _emit(s: String) -> void:
	_out.store_line(s)
	_out.flush()


func _process(_d: float) -> void:
	var now := Time.get_ticks_usec()
	var dt := now - _last_us
	_last_us = now
	var phys := Engine.get_physics_frames()
	var ticks := phys - _last_phys
	_last_phys = phys
	var added := _added
	_added = {}
	_n += 1
	var gm = get_node_or_null("/root/GameManager")
	if gm == null:
		return
	match _phase:
		"boot":
			if _n > 900:
				_load()
		"load":
			_load_max_us = maxi(_load_max_us, dt)
			if gm.game_state == gm.LEVEL_ACTIVE and gm.player_state == gm.PLAYER_ACTIVE:
				_phase = "settle"
				_n = 0
		"settle":
			# Invincible from here: player_detectors disables the health collider
			# on its own tick, so it must be off before the teleport.
			gm.player_health_state = gm.PLAYER_INVINCIBLE
			gm.player_invincible_timer = 10.0
			if _n >= SETTLE_FRAMES:
				_start_ride(gm)
		"ride":
			# Kept invincible: otherwise the teleported player is hurt on its
			# first tick there and the ride ends (LEVEL_PAUSE stops the wire).
			gm.player_health_state = gm.PLAYER_INVINCIBLE
			gm.player_invincible_timer = 10.0
			var on: bool = _player.on_zipwire
			var gold: int = gm.total_level_gold_collected - _gold0
			var a := ""
			for k: String in added:
				a += "%s:%d," % [k, added[k]]
			_rows.append([dt, ticks, on, gold, added])
			_emit("F %d %d %d %d %d %d %s %s" % [_ride, _n, dt, ticks, int(on), gold, a, _diag()])
			if on:
				_was_on = true
			elif _was_on:
				_off_frames += 1
			if _off_frames >= TAIL_FRAMES or _n > 900:
				_end_ride(gold)


# Diagnostics per frame: engine frame index (= MISTER_FRAMELOG record), player
# position and state, camera centre, coins alive / visible.
func _diag() -> String:
	var alive := 0
	var vis := 0
	for g: Node in _golds:
		if is_instance_valid(g):
			alive += 1
			if g.is_visible():
				vis += 1
	var cam := get_viewport().get_camera_2d()
	var cp: Vector2 = cam.get_screen_center_position() if cam != null else Vector2.ZERO
	var st = _player.get_node_or_null("player_state_machine")
	var sn: String = str(st.current_state.name) if st != null and st.get(&"current_state") != null else "?"
	var gm = get_node("/root/GameManager")
	return "pf=%d p=%d,%d st=%s gs=%d ps=%d cam=%d,%d gold_alive=%d gold_vis=%d" % [Engine.get_process_frames(),
			_player.global_position.x, _player.global_position.y, sn, gm.game_state, gm.player_state, cp.x, cp.y, alive, vis]


func _load() -> void:
	var gm = get_node("/root/GameManager")
	gm.reset_game_variables()
	gm.reset_round_variables()
	gm.current_level_index = 4
	gm.reset_level_variables()
	_load_max_us = 0
	get_node("/root/Signals").emit_load_scene(get_node("/root/GlobalVariables").LEVELS[4])
	_phase = "load"


func _start_ride(gm) -> void:
	var root := get_tree().root
	var rig: Node = root.find_child(WIRES[_ride % 2], true, false)
	_player = root.find_child("player", true, false)
	var zw: Node = rig.get_node("zipwire")
	if gm.player_lives < 5:
		gm.player_lives = 5
	gm.player_health_state = gm.PLAYER_INVINCIBLE
	gm.player_invincible_timer = 10.0
	# As _on_zipwire_collider_area_entered + the jump state's on_zipwire branch
	# would: the zipwire state's enter() activates the wire.
	_player.global_position = zw.get_node("player_target_position").global_position + Vector2(0, 2)
	_player.velocity = Vector2(0, 1)
	_player.active_zipwire = zw
	_player.on_zipwire = true
	var sm: Node = _player.get_node("player_state_machine")
	sm.change_state(sm.get_node("player_zipwire_state"))
	_golds.assign(root.find_children("*", "Area2D", true, false).filter(
			func(n: Node) -> bool: return n.get_script() != null and n.get(&"mega_gold") != null))
	_gold0 = gm.total_level_gold_collected
	_rows = []
	_was_on = false
	_off_frames = 0
	_n = 0
	_phase = "ride"


func _end_ride(gold: int) -> void:
	var frames := _rows.size()
	var ticks := 0
	var multi := 0
	var over := 0
	var maxdt := 0
	var inst := {}
	for r: Array in _rows:
		ticks += r[1]
		if r[1] >= 2:
			multi += 1
		if r[0] > 17500:
			over += 1
		maxdt = maxi(maxdt, r[0])
		for k: String in r[4]:
			inst[k] = inst.get(k, 0) + r[4][k]
	var s := ""
	for k: String in inst:
		s += "%s:%d," % [k, inst[k]]
	_emit("R %d wire=%s gold=%d frames=%d ticks=%d multi_tick_frames=%d frames_over_17.5ms=%d max_frame_us=%d load_max_frame_us=%d inst=%s"
			% [_ride, WIRES[_ride % 2], gold, frames, ticks, multi, over, maxdt, _load_max_us, s])
	_ride += 1
	if _ride >= RIDES:
		_emit("DONE")
		_phase = "done"
		return
	_load()
