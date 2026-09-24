extends Node
# Measurement only (autoload via the stutter harness's override.cfg; never shipped). Prints a
# STATE line whenever GameManager's game/player state changes and a SCENE line
# for every scene file instantiated, keyed by Engine.get_process_frames(), which
# equals the MISTER_FRAMELOG record index (both count Main::iteration calls).

var _gs = -1
var _ps = -1
# MISTER_TEST_LIVES=<n> (harness default 99): keep lives topped up while a game
# runs, so the player dies and respawns as usual but never reaches game over.
var _lives := OS.get_environment("MISTER_TEST_LIVES").to_int()
# STATE/SCENE lines go to their own tmpfs file, flushed per line: the engine's
# stdout is block-buffered in release builds (flush_stdout_on_print is off),
# and joy_drive.py needs the state promptly. MISTER_TEST_STATE_FILE, else stdout.
var _out: FileAccess = null


func _emit(line: String) -> void:
	if _out != null:
		_out.store_line(line)
		_out.flush()
	else:
		print(line)


func _ready() -> void:
	var path := OS.get_environment("MISTER_TEST_STATE_FILE")
	if path != "":
		_out = FileAccess.open(path, FileAccess.WRITE)
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100000
	get_tree().node_added.connect(_on_added)


func _on_added(n: Node) -> void:
	if n.scene_file_path != "":
		_emit("SCENE f=%d %s" % [Engine.get_process_frames(), n.scene_file_path.get_file()])


func _process(_delta: float) -> void:
	var gm = get_node_or_null("/root/GameManager")
	if gm == null:
		return
	if _lives > 0 and gm.game_state != 0 and gm.player_lives < _lives:
		gm.player_lives = _lives
	if gm.game_state != _gs or gm.player_state != _ps:
		_gs = gm.game_state
		_ps = gm.player_state
		_emit("STATE f=%d gs=%d ps=%d" % [Engine.get_process_frames(), _gs, _ps])
