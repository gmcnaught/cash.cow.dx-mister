extends SceneTree
# Device micro-benchmark: cost per operation of GDScript access forms (release
# engine, headless). 20000 iterations each; reports ns/op minus an empty loop.

const ACTIVE: String = "active"
var node: Node2D
var spr: AnimatedSprite2D
var holder: Node # script object with a member, stands in for GameManager / owner.x


func _init() -> void:
	node = Node2D.new()
	root.add_child.call_deferred(node)
	spr = AnimatedSprite2D.new()
	var sf := SpriteFrames.new()
	sf.add_animation(&"active")
	sf.add_frame(&"active", PlaceholderTexture2D.new())
	spr.sprite_frames = sf
	root.add_child.call_deferred(spr)
	var gd := GDScript.new()
	gd.source_code = "extends Node\nvar game_state: int = 2\n"
	gd.reload()
	holder = Node.new()
	holder.set_script(gd)
	_run.call_deferred()


func _t(label: String, base: float, us: int) -> void:
	print("BENCH %-44s %7.0f ns/op" % [label, us * 1000.0 / 20000.0 - base])


func _run() -> void:
	await process_frame
	var n := 20000
	var t: int
	var b := 0
	var v: Vector2
	var x: bool
	var i := 0
	t = Time.get_ticks_usec()
	for k in n: i += 1
	var base := (Time.get_ticks_usec() - t) * 1000.0 / n
	print("BENCH empty loop %.0f ns/iter (subtracted)" % base)

	t = Time.get_ticks_usec()
	for k in n: v = node.global_position
	_t("node.global_position (property)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: v = node.get_global_position()
	_t("node.get_global_position() (typed call)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: node.visible = true
	_t("node.visible = true (property)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: node.set_visible(true)
	_t("node.set_visible(true) (typed call)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: x = node.visible
	_t("x = node.visible (property)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: x = node.is_visible()
	_t("x = node.is_visible() (typed call)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: spr.play(ACTIVE)
	_t("spr.play(ACTIVE String const)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: spr.play(&"active", 1.0, false)
	_t("spr.play(&\"active\", 1.0, false) (validated)", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: i = holder.game_state
	_t("holder.game_state (other script's member)", base, Time.get_ticks_usec() - t)
	var h = holder
	t = Time.get_ticks_usec()
	for k in n: i = h.game_state
	_t("untyped h.game_state", base, Time.get_ticks_usec() - t)
	t = Time.get_ticks_usec()
	for k in n: _noop()
	_t("self script function call _noop()", base, Time.get_ticks_usec() - t)
	quit()


func _noop() -> void:
	pass
