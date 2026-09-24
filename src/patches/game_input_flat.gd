extends "res://game_input/GameInput.gd"
# MiSTer patch for the GameInput autoload: the original tick makes 42 script
# calls and converts a String action name to a StringName for each of ~24
# Input.is_action_pressed() calls. Same logic inlined, with StringName literals
# and the explicit exact_match=false so each call is a validated direct call.
# Order matters and is kept: up sees last tick's down, down sees this tick's up
# (same for left/right); just_* compare against previous_frame before it updates.


func _physics_process(_delta: float) -> void:
	var p: bool
	var prev: bool

	# up (reads p1_down_pressed from the previous tick, as the original does)
	p = false
	if not p1_down_pressed:
		p = Input.is_action_pressed(&"p1_up_keyboard", false) or Input.is_action_pressed(&"p1_up_dpad", false) or Input.is_action_pressed(&"p1_up_analog", false)
	prev = p1_up_previous_frame
	p1_up_pressed = p
	p1_up_just_pressed = p and not prev
	p1_up_just_released = not p and prev
	p1_up_previous_frame = p

	# down (reads this tick's up)
	p = false
	if not p1_up_pressed:
		p = Input.is_action_pressed(&"p1_down_keyboard", false) or Input.is_action_pressed(&"p1_down_dpad", false) or Input.is_action_pressed(&"p1_down_analog", false)
	prev = p1_down_previous_frame
	p1_down_pressed = p
	p1_down_just_pressed = p and not prev
	p1_down_just_released = not p and prev
	p1_down_previous_frame = p

	# left (reads p1_right_pressed from the previous tick)
	p = false
	if not p1_right_pressed:
		p = Input.is_action_pressed(&"p1_left_keyboard", false) or Input.is_action_pressed(&"p1_left_dpad", false) or Input.is_action_pressed(&"p1_left_analog", false)
	prev = p1_left_previous_frame
	p1_left_pressed = p
	p1_left_just_pressed = p and not prev
	p1_left_just_released = not p and prev
	p1_left_previous_frame = p

	# right (reads this tick's left)
	p = false
	if not p1_left_pressed:
		p = Input.is_action_pressed(&"p1_right_keyboard", false) or Input.is_action_pressed(&"p1_right_dpad", false) or Input.is_action_pressed(&"p1_right_analog", false)
	prev = p1_right_previous_frame
	p1_right_pressed = p
	p1_right_just_pressed = p and not prev
	p1_right_just_released = not p and prev
	p1_right_previous_frame = p

	p = Input.is_action_pressed(&"p1_jump_keyboard", false) or Input.is_action_pressed(&"p1_jump_controller", false)
	prev = p1_jump_previous_frame
	p1_jump_pressed = p
	p1_jump_just_pressed = p and not prev
	p1_jump_just_released = not p and prev
	p1_jump_previous_frame = p

	p = Input.is_action_pressed(&"p1_start_keyboard", false) or Input.is_action_pressed(&"p1_start_controller", false)
	prev = p1_start_previous_frame
	p1_start_pressed = p
	p1_start_just_pressed = p and not prev
	p1_start_just_released = not p and prev
	p1_start_previous_frame = p

	p = Input.is_action_pressed(&"p1_select_keyboard", false) or Input.is_action_pressed(&"p1_select_controller", false)
	prev = p1_select_previous_frame
	p1_select_pressed = p
	p1_select_just_pressed = p and not prev
	p1_select_just_released = not p and prev
	p1_select_previous_frame = p

	p = Input.is_action_pressed(&"p1_accept_keyboard", false) or Input.is_action_pressed(&"p1_accept_controller", false)
	prev = p1_accept_previous_frame
	p1_accept_pressed = p
	p1_accept_just_pressed = p and not prev
	p1_accept_just_released = not p and prev
	p1_accept_previous_frame = p

	p = Input.is_action_pressed(&"p1_cancel_keyboard", false) or Input.is_action_pressed(&"p1_cancel_controller", false)
	prev = p1_cancel_previous_frame
	p1_cancel_pressed = p
	p1_cancel_just_pressed = p and not prev
	p1_cancel_just_released = not p and prev
	p1_cancel_previous_frame = p

	p = Input.is_action_pressed(&"pause_keyboard", false) or Input.is_action_pressed(&"pause_controller", false)
	prev = pause_previous_frame
	pause_pressed = p
	pause_just_pressed = p and not prev
	pause_just_released = not p and prev
	pause_previous_frame = p

	all_buttons_released = not p1_up_pressed and not p1_down_pressed and not p1_left_pressed and not p1_right_pressed and not p1_jump_pressed
