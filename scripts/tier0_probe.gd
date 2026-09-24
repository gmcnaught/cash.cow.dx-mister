extends Node
# Tier-0 headless measurement harness. Loaded as an extra autoload via
# override.cfg next to the engine binary; the game's pck is not modified.
#
# 1. Headless never renders, so VisibleOnScreenEnabler2D never fires and the
#    nodes it guards (cast_panel, gold pickups) stay PROCESS_MODE_DISABLED. The
#    attract loop then stalls on cast_panel. The game is a single 320x240
#    screen, so everything is on screen in real play: emulate that by applying
#    each enabler's enable_mode to its target when the enabler enters the tree.
# 2. Once per second print the active attract panel and the process CPU cost
#    per frame from /proc/self/stat (utime+stime, all threads). This excludes
#    the headless frame-pacing sleep, which caps fps at ~145.

const CLK_TCK: float = 100.0

var acc: float = 0.0
var frames: int = 0
var last_ticks: int = -1
var last_phys: int = 0


func _ready() -> void:
	# Event-driven instead of scanning the tree (a full find_children scan cost ~23 ms).
	get_tree().node_added.connect(_on_node_added)


func _process(delta: float) -> void:
	frames += 1
	acc += delta
	if acc < 1.0:
		return
	var ticks := _cpu_ticks()
	if last_ticks >= 0:
		var cpu_ms := (ticks - last_ticks) * 1000.0 / CLK_TCK
		var phys := Engine.get_physics_frames()
		print("PROBE t=%d panel=%s ticks=%d frames=%d cpu_ms_per_frame=%.2f cpu_pct=%.0f nodes=%d" % [
			Time.get_ticks_msec() / 1000, _panel_name(), phys - last_phys, frames, cpu_ms / frames,
			cpu_ms / (acc * 10.0), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	last_ticks = ticks
	last_phys = Engine.get_physics_frames()
	acc = 0.0
	frames = 0


func _on_node_added(n: Node) -> void:
	# TIER0_ENABLERS=all (default) | panels (skip gold pickups) | none
	if not n is VisibleOnScreenEnabler2D:
		return
	var mode := OS.get_environment("TIER0_ENABLERS")
	if mode == "none":
		return
	# Deferred: the enabler disables its target when it enters the tree.
	_apply_enabler.call_deferred(n, mode)


func _apply_enabler(e: VisibleOnScreenEnabler2D, mode: String) -> void:
	if not is_instance_valid(e) or not e.is_inside_tree():
		return
	var target := e.get_node_or_null(e.enable_node_path)
	if target == null or (mode == "panels" and target is Area2D):
		return
	match e.enable_mode:
		VisibleOnScreenEnabler2D.ENABLE_MODE_ALWAYS:
			target.process_mode = Node.PROCESS_MODE_ALWAYS
		VisibleOnScreenEnabler2D.ENABLE_MODE_WHEN_PAUSED:
			target.process_mode = Node.PROCESS_MODE_WHEN_PAUSED
		_:
			target.process_mode = Node.PROCESS_MODE_INHERIT


func _panel_name() -> String:
	var ap := get_tree().root.find_child("attract_panel", true, false)
	if ap and "current_panel_index" in ap:
		return str(ap.panels[ap.current_panel_index].name)
	var cs := get_tree().current_scene
	return cs.name if cs else "?"


func _cpu_ticks() -> int:
	var f := FileAccess.open("/proc/self/stat", FileAccess.READ)
	if f == null:
		return 0
	var s := f.get_line()  # /proc files report length 0, so get_as_text() is empty
	# After the ")" that ends comm: index 0 is state (field 3), so utime (14) is 11, stime (15) is 12.
	var rest := s.substr(s.rfind(")") + 2).split(" ")
	return int(rest[11]) + int(rest[12])
