extends SceneTree
# Semantic check for the GET/SET_NAMED inline cache (PLAN §6.16). Run on an
# engine with and without the cache; the printed lines must be identical.

var out: PackedStringArray = []

func p(s) -> void:
	out.append(str(s))


func mk(src: String) -> Object:
	var gd := GDScript.new()
	gd.source_code = src
	gd.reload()
	return gd


func _init() -> void:
	var s_plain: GDScript = mk("extends Node2D\nvar a = 1\nvar b: int = 2\nvar c: float = 0.5\nconst K = 7\nstatic var sv = 11\nsignal sig\nfunc m(): return 3\n")
	var s_setget: GDScript = mk("extends Node2D\nvar log = []\nvar x: int = 0:\n\tset(v):\n\t\tlog.append(v)\n\t\tx = v * 2\n\tget:\n\t\treturn x + 1\n")
	var s_dyn: GDScript = mk("extends Node2D\nvar store = {}\nfunc _get(n):\n\tif n == &\"visible\": return \"shadowed\"\n\treturn store.get(n)\nfunc _set(n, v):\n\tif n == &\"position\": store[n] = v; return true\n\treturn false\n")
	# Inherited script: an inner class extending an inner base, instantiated via the outer script.
	var s_inh: GDScript = mk("extends Node2D\nclass Base extends Node2D:\n\tvar a = 100\n\tconst BK = 5\nclass Child extends Base:\n\tvar d = 4\nstatic func make(): return Child.new()\n")

	var objs: Array = []
	for scr in [s_plain, s_setget, s_dyn]:
		var n := Node2D.new()
		n.set_script(scr)
		root.add_child(n)
		objs.append(n)
	var plain_native := Node2D.new()
	root.add_child(plain_native)
	var spr := Sprite2D.new()
	root.add_child(spr)

	var o = objs[0]
	# untyped member get/set
	for i in 3:
		o.a = o.a + i
	p(["a", o.a])
	# typed member: exact type, then conversion (float -> int), then int -> float
	o.b = 5
	p(["b exact", o.b, typeof(o.b)])
	o.b = 7.9
	p(["b conv", o.b, typeof(o.b)])
	o.c = 3
	p(["c conv", o.c, typeof(o.c)])
	# constant, static, method, signal via instance
	p(["K", o.K])
	p(["sv", o.sv])
	o.sv = 12
	p(["sv2", o.sv, s_plain.sv])
	p(["m", o.m.call()])
	p(["sig", typeof(o.sig)])
	# native props on scripted and plain objects, typed and untyped
	for n in [o, plain_native, spr, objs[1]]:
		n.position = Vector2(1, 2)
		n.visible = false
		n.visible = true
		n.position += Vector2(3, 4)
		p([n.get_class(), n.position, n.visible, n.z_index])
	# setter/getter member
	var sg = objs[1]
	for i in 3:
		sg.x = i
	p(["setget", sg.x, sg.log])
	# _get/_set shadowing
	var dy = objs[2]
	dy.position = Vector2(9, 9)
	p(["dyn position (via _set -> store)", dy.store, dy.position])
	p(["dyn visible (shadowed by _get)", dy.visible])
	# one site, many classes (polymorphic)
	var mixed: Array = [o, plain_native, spr, sg, dy, o, spr]
	for n in mixed:
		p(["poly", n.get_class(), n.visible, n.position, n.name if n.name else ""])
	# property that doesn't exist -> null in release (via get)
	p(["missing", o.get("nope")])
	# members/constants of a base script through a derived instance
	var ch = s_inh.make()
	root.add_child(ch)
	for i in 2:
		ch.a += 1
		ch.d += 1
	p(["inherit", ch.a, ch.d, ch.BK, ch.visible])
	# typed reference to a native class
	var t: Node2D = plain_native
	for i in 3:
		t.rotation = i * 0.5
	p(["typed rot", t.rotation])
	for line in out:
		print("NCT ", line)
	quit()
