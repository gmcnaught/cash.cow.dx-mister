extends Node
# Measurement only (scripts/zipride/run.sh PROBE=poly SHOTS=1): does a Polygon2D reach the
# fabric bridge? After boot, adds an untextured red Polygon2D and a textured one (the disco
# lights atlas) on a CanvasLayer over the attract screen; one W line for the screenshot.
# Read the bridge's poly= counter with EXTRA_ENV="export MISTER_FABRIC_STATS=30".

var _n := 0
var _out: FileAccess


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var path := OS.get_environment("ZIPPROBE_OUT")
	_out = FileAccess.open(path if path != "" else "/tmp/cc_zip.txt", FileAccess.WRITE)


func _process(_d: float) -> void:
	_n += 1
	if _n == 600:
		var layer := CanvasLayer.new()
		layer.layer = 100
		add_child(layer)
		var red := Polygon2D.new()
		red.color = Color(1, 0, 0)
		red.polygon = PackedVector2Array([Vector2(20, 40), Vector2(140, 40), Vector2(140, 200), Vector2(20, 200)])
		layer.add_child(red)
		var tex := Polygon2D.new()
		tex.texture = load("res://objects/disco/disco_lights.png")
		var cone := PackedVector2Array([Vector2(55, 0), Vector2(73, 0), Vector2(121, 256), Vector2(7, 256)])
		tex.polygon = cone
		tex.uv = cone
		tex.position = Vector2(170, -10)
		layer.add_child(tex)
	elif _n == 700:
		_out.store_line("W poly %d" % Engine.get_process_frames())
		_out.flush()
	elif _n == 760:
		_out.store_line("E poly %d" % Engine.get_process_frames())
		_out.store_line("DONE")
		_out.flush()
