extends SceneTree
# Device micro-benchmark: cost of starting each game SFX (release engine, headless).
#   godot --headless --main-pack CashCowDX.pck --script sfx_bench.gd
# Per sound: length, loop, rate; instantiate_playback() us; start(0) us (= seek(0) decode).

func _init() -> void:
	var dir := "res://sounds/sfx/"
	var files: Array[String] = []
	for f in DirAccess.open(dir).get_files():
		files.append(f.trim_suffix(".import").trim_suffix(".remap"))
	var seen := {}
	var tot_len := 0.0
	var tot_inst := 0.0
	var tot_start := 0.0
	print("SFX name len_s loop rate inst_us start_us")
	for f in files:
		if not f.ends_with(".ogg") or seen.has(f):
			continue
		seen[f] = true
		var s: AudioStreamOggVorbis = load(dir + f)
		var n := 10
		var t_inst := 0
		var t_start := 0
		for i in n:
			var t0 := Time.get_ticks_usec()
			var pb := s.instantiate_playback()
			var t1 := Time.get_ticks_usec()
			pb.start(0.0)
			var t2 := Time.get_ticks_usec()
			pb.stop()
			t_inst += t1 - t0
			t_start += t2 - t1
		var rate := 0
		tot_len += s.get_length()
		tot_inst += t_inst / float(n)
		tot_start += t_start / float(n)
		print("SFX %s %.2f %s %d %d" % [f, s.get_length(), s.loop, t_inst / n, t_start / n])
	print("SFX_TOTAL count=%d len_s=%.1f mean_inst_us=%d mean_start_us=%d" % [seen.size(), tot_len, tot_inst / seen.size(), tot_start / seen.size()])
	quit()
