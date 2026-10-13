extends Node
# Measurement only (autoload via scripts/zipride/run.sh PROBE=scan; never shipped).
# Render-cost attribution on stage 5. Loads stage 5, then holds the player (kept
# invincible, so nothing ends the hold) at a series of x positions; the camera
# follows (camera.gd: x = player x - 160). At HOLD_X it also hides each
# top-level child of the level in turn. Each window is logged as
# "W <label> <first frame> <last frame>" with Engine.get_process_frames(), the
# MISTER_FRAMELOG record index; frames.bin gives draw / present per window.
# ZIPPROBE_MODE=lights: at HOLD_X only, variants of the disco lights (rotation
# 0, cone-shaped polygon instead of the 128x256 quad, both, one light).
# The cone variants draw nothing on this engine's fabric path (Polygon2D:
# poly=0 in MISTER_FABRIC_STATS, PLAN §6.29): they measure no lights.
# ZIPPROBE_MODE=parity: at HOLD_X, everything but the lights and the level art
# hidden, the lights frozen at POSES (rotation left / right, frame); run.sh
# SHOTS=1 takes one MiSTer screenshot per W line, to compare patch sets.

const XS := [288, 400, 480, 560, 640, 704, 768, 864, 960, 1100]
const HOLD_X := 704
const HOLD_Y := 60.0
const SETTLE := 40
const MEASURE := 60

var _out: FileAccess
var _phase := "boot"
var _n := 0
var _steps: Array = [] # [label, x, node to hide or null]
var _step := -1
var _player: Node = null
var _hidden: CanvasItem = null
var _lights_mode := OS.get_environment("ZIPPROBE_MODE") == "lights"
var _parity_mode := OS.get_environment("ZIPPROBE_MODE") == "parity"
const POSES := [[-0.2, 0.25, 1], [-0.05, 0.31, 3], [-0.29, 0.18, 0]]
var _disco: Node = null
var _cones: Array[Polygon2D] = []
const CONE := [Vector2(55, 0), Vector2(73, 0), Vector2(121, 256), Vector2(7, 256)]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -100000 # Before the level: the player is placed before its tick.
	var path := OS.get_environment("ZIPPROBE_OUT")
	_out = FileAccess.open(path if path != "" else "/tmp/cc_zip.txt", FileAccess.WRITE)


func _emit(s: String) -> void:
	_out.store_line(s)
	_out.flush()


func _physics_process(_d: float) -> void:
	if _phase == "scan" and _player != null:
		var gm = get_node("/root/GameManager")
		gm.player_health_state = gm.PLAYER_INVINCIBLE
		gm.player_invincible_timer = 10.0
		_player.global_position = Vector2(_steps[_step][1], HOLD_Y)
		_player.velocity = Vector2.ZERO


func _process(_d: float) -> void:
	_n += 1
	var gm = get_node_or_null("/root/GameManager")
	if gm == null:
		return
	match _phase:
		"boot":
			if _n > 900:
				gm.reset_game_variables()
				gm.reset_round_variables()
				gm.current_level_index = 4
				gm.reset_level_variables()
				get_node("/root/Signals").emit_load_scene(get_node("/root/GlobalVariables").LEVELS[4])
				_phase = "load"
		"load":
			if gm.game_state == gm.LEVEL_ACTIVE and gm.player_state == gm.PLAYER_ACTIVE:
				_build_steps()
				_phase = "scan"
				_next()
		"scan":
			if _n == SETTLE:
				_emit("W %s %d" % [_steps[_step][0], Engine.get_process_frames()])

			elif _n == SETTLE + (240 if _parity_mode else MEASURE): # Parity: time for the screenshot.
				_emit("E %s %d" % [_steps[_step][0], Engine.get_process_frames()])
				_next()


func _build_steps() -> void:
	var root := get_tree().root
	_player = root.find_child("player", true, false)
	var level: Node = root.find_child("zipwires", true, false).get_parent()
	if _parity_mode:
		_disco = level.get_node("disco_lights")
		for c: Node in level.get_children():
			if c is CanvasItem and c != _disco and c.name != "background_sprite":
				(c as CanvasItem).set_visible(false)
		for i in POSES.size():
			_steps.append(["pose%d" % i, HOLD_X, null])
		return
	if _lights_mode:
		_disco = level.get_node("disco_lights")
		for side: String in ["left", "right"]:
			var spr: AnimatedSprite2D = _disco.get_node("lights_%s/animated_sprite_%s" % [side, side])
			var c := Polygon2D.new()
			c.position = spr.position
			c.texture = (spr.sprite_frames.get_frame_texture(&"active", 0) as AtlasTexture).atlas
			c.polygon = PackedVector2Array(CONE)
			c.uv = PackedVector2Array(CONE)
			c.visible = false
			spr.get_parent().add_child(c)
			spr.get_parent().move_child(c, spr.get_index())
			_cones.append(c)
		for v: String in (OS.get_environment("ZIPPROBE_VARIANTS").split(",") if OS.get_environment("ZIPPROBE_VARIANTS") != ""
				else ["ref", "lights_hidden", "rot0", "cone", "cone_rot0", "left_only", "right_only", "ref2"]):
			_steps.append([v, HOLD_X, null])
		return
	for x: int in XS:
		_steps.append(["x%d" % x, x, null])
	_steps.append(["hold_ref", HOLD_X, null])
	for c: Node in level.get_children():
		if c is CanvasItem and c != _player and (c as CanvasItem).is_visible():
			_steps.append(["hide_" + c.name, HOLD_X, c])
	_steps.append(["hold_ref2", HOLD_X, null])


func _next() -> void:
	if _hidden != null:
		_hidden.set_visible(true)
		_hidden = null
	_step += 1
	_n = 0
	if _step >= _steps.size():
		_emit("DONE")
		_phase = "done"
		return
	if _lights_mode:
		_lights_variant(_steps[_step][0])
		return
	if _parity_mode:
		_pose(POSES[_step])
		return
	var h = _steps[_step][2]
	if h != null:
		_hidden = h
		_hidden.set_visible(false)


func _lights_variant(v: String) -> void:
	var rot0 := v.ends_with("rot0")
	var cone := v.begins_with("cone")
	_disco.set_visible(v != "lights_hidden")
	if v in ["ref", "ref2", "lights_hidden"]:
		return # As the running patch set draws them (no sprite changes).
	var i := 0
	for side: String in ["left", "right"]:
		var lights: Node2D = _disco.get_node("lights_" + side)
		var spr: AnimatedSprite2D = lights.get_node("animated_sprite_" + side)
		var ap: AnimationPlayer = lights.get_node("animation_player_" + side)
		ap.active = not rot0
		if rot0:
			lights.rotation = 0.0
		var on := not ((v == "left_only" and side == "right") or (v == "right_only" and side == "left"))
		spr.visible = on and not cone
		# rot_short: 220 px tall (the bridge splits rects over 224 px on screen).
		spr.scale = Vector2(1.0, 220.0 / 256.0) if v == "rot_short" else Vector2.ONE
		# rot_still: no frame changes (the sprite stays on its current frame).
		if v == "rot_still":
			spr.pause()
		elif not spr.is_playing():
			spr.play()
		_cones[i].visible = on and cone
		i += 1


func _pose(p: Array) -> void:
	# Disabled: no game tick (its play() calls), no sprite or AnimationPlayer
	# advance, no speed changes; drawing is unaffected.
	_disco.process_mode = Node.PROCESS_MODE_DISABLED
	var i := 0
	for side: String in ["left", "right"]:
		var lights: Node2D = _disco.get_node("lights_" + side)
		lights.rotation = p[i]
		(lights.get_node("animated_sprite_" + side) as AnimatedSprite2D).set_frame_and_progress(p[2], 0.0)
		i += 1
