extends Node
# MiSTer runtime patches, loaded as an autoload from override.cfg. Each patch is
# a subclass of a game script (`extends "res://..."`) that overrides the hot
# per-tick function; the game's pack is not modified.
#  - Scene scripts are swapped when the node enters the tree (before _ready).
#  - The GameInput autoload is already in the tree (its _ready has run; what it
#    set lives on the node and Input), so it is swapped once, here.
#  - Pools: the effect and "+N" popup managers reuse nodes instead of
#    instantiate/queue_free per spawn. Pooled nodes are still instantiated
#    from the original scenes, so they get their script swap (and VISUAL_TICK)
#    here like any other node; parked ones are hidden and PROCESS_MODE_DISABLED.
# MISTER_SEED=<n> seeds the global RNG (measurement runs). MISTER_PATCHES=0 disables all; MISTER_PATCHES_SKIP=gold,input,enemy,enemytick,playerdet,warp,visual,pool_score,pool_score_mgr,pool_fx,pool_fx_mgr skips some.

const DEFAULT_DIR := "/media/fat/games/cashcow/patches/"
var _dir := DEFAULT_DIR # MISTER_PATCHES_DIR overrides (A/B of patch versions).
# key: [original script, patch file, (more pairs under the same key)...]
const SCENE_PATCHES := {
	"gold": ["res://objects/gold/gold.gd", "gold_pixel_bob.gd"],
	"enemy": ["res://enemies/enemies_generic/enemy_detectors.gd", "enemy_detectors_flat.gd"],
	"enemytick": ["res://enemies/enemies_generic/enemy.gd", "enemy_flat.gd"],
	"playerdet": ["res://player/player_detectors.gd", "player_detectors_flat.gd"],
	"warp": ["res://generic/screen_warp/screen_warp.gd", "screen_warp_flat.gd"],
	"pool_score": ["res://ui/pickup_score/pickup_score.gd", "pickup_score_pool.gd"],
	"pool_score_mgr": ["res://ui/pickup_score/pickup_score_manager.gd", "pickup_score_manager_pool.gd"],
	"pool_fx": ["res://objects/effect/pickup_effect.gd", "effect_pool.gd",
			"res://generic/delete_on_animation_end/delete_on_animation_end.gd", "effect_delete_pool.gd"],
	"pool_fx_mgr": ["res://objects/effect/effect_manager.gd", "effect_manager_pool.gd"],
}
const INPUT_ORIG := "res://game_input/GameInput.gd"
# Scripts whose _physics_process only drives visuals (checked: no writes to
# GameManager/GlobalVariables, no signal emits or sounds in the tick). They
# run once per rendered frame instead of once per physics tick: in a catch-up
# frame physics runs up to max_physics_steps_per_frame (8) times.
const VISUAL_TICK := [
	"res://objects/gold/gold.gd",
	"res://ui/hud/info.gd",
	"res://ui/hud/p1.gd",
	"res://ui/hud/mooney.gd",
	"res://ui/pickup_score/pickup_score.gd",
	"res://ui/enemy_warning/enemy_warning.gd",
	"res://ui/extra/extra.gd",
	"res://generic/sprite_shaker/sprite_shaker.gd",
	"res://objects/shaft_arrows/shaft_arrows.gd",
	"res://objects/effect/eye_effect.gd",
	"res://objects/effect/danger_warning_sign.gd",
	"res://objects/disco/disco_lights.gd",
]

var _by_path := {} # original script path -> patch Script
var _swaps := {}
var _visual_on := false
var _visual: Array[Node] = []


func _enter_tree() -> void:
	var sd := OS.get_environment("MISTER_SEED")
	if sd != "":
		seed(sd.to_int()) # Measurement runs: same global RNG sequence each run.
	if OS.get_environment("MISTER_PATCHES") == "0":
		return
	var d := OS.get_environment("MISTER_PATCHES_DIR")
	if d != "":
		_dir = d.trim_suffix("/") + "/"
	var skip := OS.get_environment("MISTER_PATCHES_SKIP").split(",")
	for key: String in SCENE_PATCHES:
		if not skip.has(key):
			var e: Array = SCENE_PATCHES[key]
			for i in range(0, e.size(), 2):
				_by_path[e[i]] = load(_dir + e[i + 1])
	if not skip.has("input"):
		var gi := get_node_or_null("/root/GameInput")
		if gi != null and gi.get_script() != null and gi.get_script().resource_path == INPUT_ORIG:
			gi.set_script(load(_dir + "game_input_flat.gd"))
			print("MisterPatches: game_input_flat active")
	_visual_on = not skip.has("visual")
	process_priority = -1000 # Before the level's own _process callbacks.
	process_mode = Node.PROCESS_MODE_ALWAYS # Each node's can_process() decides, incl. pause.
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	var s: Script = n.get_script()
	if s == null:
		return
	var path := s.resource_path
	if _visual_on and VISUAL_TICK.has(path):
		# Godot enables the physics callback during READY; turn it off after.
		n.ready.connect(_to_visual.bind(n), CONNECT_ONE_SHOT)
	var patch: Script = _by_path.get(path)
	if patch == null:
		return
	# set_script() drops the old instance's member values. This runs before
	# _ready, so they are the scene's exported values and the defaults: carry
	# every script variable across (e.g. mega_gold, an enemy's hard_limit_*).
	var saved := {}
	for pname: String in _script_vars(s):
		saved[pname] = n.get(pname)
	n.set_script(patch)
	for k: String in saved:
		n.set(k, saved[k])
	if not _swaps.has(s.resource_path):
		_swaps[s.resource_path] = true
		print("MisterPatches: %s -> %s" % [s.resource_path, patch.resource_path.get_file()])


# Script-variable names per script, computed once: node.get_property_list()
# also walks every native property and cost ~9 ms per level load (PLAN §6.12).
var _vars_cache := {}


func _script_vars(s: Script) -> PackedStringArray:
	var names: PackedStringArray = _vars_cache.get(s, PackedStringArray())
	if names.is_empty() and not _vars_cache.has(s):
		for prop in s.get_script_property_list():
			if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				names.append(prop.name)
		_vars_cache[s] = names
	return names


func _to_visual(n: Node) -> void:
	n.set_physics_process(false)
	_visual.append(n)
	# Leaves the list when it leaves the tree, so the per-frame loop needs no
	# validity/in-tree checks.
	n.tree_exiting.connect(_visual_exit.bind(n), CONNECT_ONE_SHOT)


func _visual_exit(n: Node) -> void:
	_visual.erase(n)


var _dbg := OS.get_environment("MISTER_PATCHES_DEBUG") == "1"
var _dbg_frames := 0


func _process(delta: float) -> void:
	if _dbg:
		_dbg_frames += 1
		if _dbg_frames % 600 == 0:
			print("MisterPatches: %d nodes ticked per frame" % _visual.size())
	for n: Node in _visual:
		if n.can_process(): # Pause and the on-screen enablers, as for its own callbacks.
			n._physics_process(delta)
