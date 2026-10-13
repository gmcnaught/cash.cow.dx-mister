extends "res://objects/disco/disco_lights.gd"
# MiSTer patch for objects/disco/disco_lights.gd (stage 5's two stage lights,
# behind the boss). Each light is a 128x256 AnimatedSprite2D that its
# AnimationPlayer keeps rotating (left -17..0 degrees, right 10..19). On the
# fabric a rotated textured quad of that size is slow: with the camera on the
# boss area the present waited ~22 ms a frame (7 ms with the lights hidden
# or at rotation 0), so frames ran over and physics caught up with 2 steps
# (the zipwire slowdown over the Party Pig). The lights are drawn as their
# opaque texels instead: untextured rects, one per row run of the cone, in
# the frame's colour, so the fabric draws the same pixels without sampling a
# rotated texture (scripts/zipride/, PLAN §6.29). Polygons would be one draw,
# but this engine's fabric bridge receives none from a Polygon2D (poly=0).
# Same patch, other parent script: disco_lights_clear_cone.gd (game clear).
# The sprites stay in the tree, hidden, and keep running the animation and
# its frame timing; the runs node follows their frame through frame_changed
# and animation_changed (redrawn only then, ~10 times a second; the rotation
# is its parent's transform, as for the sprite), at the sprite's place under
# the rotating lights_* node.

const ATLAS := "res://objects/disco/disco_lights.png"
# Every frame of disco_lights.png is one colour (by atlas column, frame width
# 128) in the same cone with binary alpha: 49 row runs, rows 0-2 x 56-71 to
# rows 253-255 x 8-119 (LightRuns.RUNS); local = texel coordinates within
# the 128x256 frame.
# The texels are (0,148,249), (0,0,249), (122,249,0), (166,6,255). The fabric
# stages textures as RGB565 and shows them expanded (249 -> 31 -> 255) but
# scales a vertex colour down (249 -> 30 -> 247), so the rects use the texels'
# RGB565 values expanded, which both paths map to the same 565 colour.
const COLORS := [Color8(0, 150, 255), Color8(0, 0, 255), Color8(123, 251, 0), Color8(165, 4, 255)]


class LightRuns extends Node2D:
	const RUNS := [
		Rect2(56, 0, 16, 3), Rect2(55, 3, 18, 5), Rect2(54, 8, 20, 6), Rect2(53, 14, 22, 5), Rect2(52, 19, 24, 5),
		Rect2(51, 24, 26, 6), Rect2(50, 30, 28, 5), Rect2(49, 35, 30, 5), Rect2(48, 40, 32, 6), Rect2(47, 46, 34, 5),
		Rect2(46, 51, 36, 5), Rect2(45, 56, 38, 6), Rect2(44, 62, 40, 5), Rect2(43, 67, 42, 5), Rect2(42, 72, 44, 6),
		Rect2(41, 78, 46, 5), Rect2(40, 83, 48, 5), Rect2(39, 88, 50, 5), Rect2(38, 93, 52, 6), Rect2(37, 99, 54, 5),
		Rect2(36, 104, 56, 5), Rect2(35, 109, 58, 6), Rect2(34, 115, 60, 5), Rect2(33, 120, 62, 5), Rect2(32, 125, 64, 6),
		Rect2(31, 131, 66, 5), Rect2(30, 136, 68, 5), Rect2(29, 141, 70, 6), Rect2(28, 147, 72, 5), Rect2(27, 152, 74, 5),
		Rect2(26, 157, 76, 6), Rect2(25, 163, 78, 5), Rect2(24, 168, 80, 5), Rect2(23, 173, 82, 5), Rect2(22, 178, 84, 6),
		Rect2(21, 184, 86, 5), Rect2(20, 189, 88, 5), Rect2(19, 194, 90, 6), Rect2(18, 200, 92, 5), Rect2(17, 205, 94, 5),
		Rect2(16, 210, 96, 6), Rect2(15, 216, 98, 5), Rect2(14, 221, 100, 5), Rect2(13, 226, 102, 6),
		Rect2(12, 232, 104, 5), Rect2(11, 237, 106, 5), Rect2(10, 242, 108, 6), Rect2(9, 248, 110, 5),
		Rect2(8, 253, 112, 3),
	]

	var color := Color.WHITE

	# Each run but the last reaches 1 row into the next, wider one (same
	# colour, still inside the cone): rotated, the runs meet at T-junctions,
	# and with vertex snapping their shared edges left 1 px gaps.
	func _draw() -> void:
		var last := RUNS.size() - 1
		for i in RUNS.size():
			var r: Rect2 = RUNS[i]
			if i < last:
				r.size.y += 1.0
			draw_rect(r, color)


var _runs_left: Node2D = null
var _runs_right: Node2D = null


func _ready() -> void:
	super()
	_runs_left = _runs_for(animated_sprite_left)
	_runs_right = _runs_for(animated_sprite_right)


# The frame's colour, or null if the frame is not one of disco_lights.png's.
func _frame_color(s: AnimatedSprite2D) -> Variant:
	var t := s.get_sprite_frames().get_frame_texture(s.get_animation(), s.get_frame()) as AtlasTexture
	if t == null or t.get_atlas() == null or t.get_atlas().get_path() != ATLAS:
		return null
	var r := t.get_region()
	var i := int(r.position.x) / 128
	if r.size != Vector2(128, 256) or r.position != Vector2(i * 128, 0) or i < 0 or i >= COLORS.size():
		return null
	return COLORS[i]


func _runs_for(s: AnimatedSprite2D) -> Node2D:
	var c = _frame_color(s)
	if c == null or s.is_centered() or s.get_offset() != Vector2.ZERO or s.is_flipped_h() or s.is_flipped_v():
		return null # Not the layout the runs were measured on: keep the sprite.
	var n := LightRuns.new()
	n.color = c
	n.set_position(s.get_position())
	var p := s.get_parent()
	p.add_child(n)
	p.move_child(n, s.get_index()) # The sprite's place in the draw order.
	s.set_visible(false)
	s.frame_changed.connect(_runs_frame.bind(s, n))
	s.animation_changed.connect(_runs_frame.bind(s, n))
	return n


func _runs_frame(s: AnimatedSprite2D, n: LightRuns) -> void:
	var c = _frame_color(s)
	if c == null:
		# A frame the table does not cover (none in this pack): show the sprite.
		s.set_visible(true)
		n.set_visible(false)
	elif c != n.color:
		n.color = c
		n.queue_redraw()
