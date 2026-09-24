extends "res://generic/screen_warp/screen_warp.gd"
# MiSTer patch for generic/screen_warp/screen_warp.gd (player + every enemy):
# track_owner_position inlined, with `owner` and its global_position read once
# instead of up to 6 times, via typed method calls (PLAN §6.10). Same checks,
# same writes, same order.


func _physics_process(_delta: float) -> void:
	var o := owner as Node2D
	var gp := o.get_global_position()
	if warp_x:
		if gp.x < left_limit:
			gp.x = right_limit
			o.set_global_position(gp)
		elif gp.x > right_limit:
			gp.x = left_limit
			o.set_global_position(gp)
	if warp_y and gp.y > bottom_limit:
		gp.y = top_limit
		o.set_global_position(gp)
		if o.name == PLAYER:
			if GameManager.player_health_state != GameManager.PLAYER_PICKAXE:
				GameManager.set_player_health_state(GameManager.PLAYER_INVINCIBLE, GlobalVariables.SHORT_INVICIBILITY)
		else:
			var cb := o as CharacterBody2D
			cb.set_velocity(Vector2(0, cb.get_velocity().y))
