extends SceneTree
# Device check: hash the decoded output of every SFX via AudioEffectCapture on
# the master bus (headless, Dummy driver mixes in real time). Compare runs with
# MISTER_OGG_SHARED=1 and =0; the hashes must match.

var cap: AudioEffectCapture
var player: AudioStreamPlayer

func _init() -> void:
	cap = AudioEffectCapture.new()
	cap.buffer_length = 3.0
	AudioServer.add_bus_effect(0, cap)
	player = AudioStreamPlayer.new()
	root.add_child.call_deferred(player)
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var dir := "res://sounds/sfx/"
	var names: Array[String] = []
	for f in DirAccess.open(dir).get_files():
		var n := f.trim_suffix(".import").trim_suffix(".remap")
		if n.ends_with(".ogg") and not names.has(n):
			names.append(n)
	names.sort()
	for n in names:
		var s: AudioStream = load(dir + n)
		cap.clear_buffer()
		player.stream = s
		player.play()
		await create_timer(s.get_length() + 0.25).timeout
		var buf := cap.get_buffer(cap.get_frames_available())
		var i := 0
		while i < buf.size() and buf[i] == Vector2.ZERO:
			i += 1
		var h := PackedFloat32Array()
		for k in range(i, buf.size()):
			h.append(buf[k].x)
			h.append(buf[k].y)
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		# Compare the clip body only; the capture tail depends on timer jitter.
		ctx.update(h.to_byte_array().slice(0, 8 * int(s.get_length() * 0.9 * AudioServer.get_mix_rate())))
		print("HASH %s %s" % [n, ctx.finish().hex_encode().substr(0, 16)])
	quit()
