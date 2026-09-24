extends "res://generic/delete_on_animation_end/delete_on_animation_end.gd"
# MiSTer patch for generic/delete_on_animation_end/delete_on_animation_end.gd
# (walk, jump, slide, drop, pickaxe-end, bonus-enter, stage-clear and
# loudspeaker-kill effects: AnimatedSprite2D, one-shot animation, then free).
# Same body as effect_pool.gd (the two game scripts are identical).
# Pooled by effect_manager_pool.gd: when the one-shot animation finishes the
# effect parks itself (paused, hidden, PROCESS_MODE_DISABLED) instead of
# queue_free(); the manager resets and restarts it for the next spawn of the
# same scene. Without that manager (_pool_owner == null) or with its pool for
# this scene full it frees itself as the original does. The original frees
# in the same callback, so the effect is never drawn after it finishes in
# either case.

var _pool_owner: Node = null # effect_manager_pool.gd, set after add_child.
var _pool_key: PackedScene = null # Scene this node was instantiated from.
# The fresh instance's state before _ready (scene values), restored on reuse.
var _anim0: StringName = &""
var _auto0: StringName = &""
var _frame0: int = 0
var _prog0: float = 0.0
var _flip0: bool = false
var _vis0: bool = true
var _mode0: ProcessMode = PROCESS_MODE_INHERIT


func _on_animation_finished() -> void:
	if _pool_owner != null and _pool_owner._fx_release(self, _pool_key):
		_pool_park()
		return
	queue_free()


func _pool_init(p_owner: Node, p_key: PackedScene, p_anim: StringName, p_auto: StringName, p_frame: int, p_prog: float, p_flip: bool, p_vis: bool) -> void:
	_pool_owner = p_owner
	_pool_key = p_key
	_anim0 = p_anim
	_auto0 = p_auto
	_frame0 = p_frame
	_prog0 = p_prog
	_flip0 = p_flip
	_vis0 = p_vis
	_mode0 = get_process_mode()


func _pool_park() -> void:
	if is_playing():
		pause() # Pre-warmed nodes; a finished animation is already paused.
	set_visible(false)
	set_process_mode(PROCESS_MODE_DISABLED)


# Fresh-instance state, then what AnimatedSprite2D's NOTIFICATION_READY does
# (autoplay: play(autoplay, 1.0, false), which keeps the scene's frame and
# frame_progress, e.g. pickaxe_end_effect's 0.623771). Position, scale and
# flip_h are set by the manager before this, as the spawn functions do.
func _pool_reuse() -> void:
	set_process_mode(_mode0)
	set_animation(_anim0)
	set_frame_and_progress(_frame0, _prog0)
	if _auto0 != &"":
		play(_auto0, 1.0, false)
	set_visible(_vis0)
