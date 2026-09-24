/**************************************************************************/
/*  display_server_mister.h                                               */
/**************************************************************************/
/* MiSTer FPGA display server for Godot 4.3 (linuxbsd).                   */
/*                                                                        */
/* No X11/Wayland/DRM on the DE10-Nano: render with Mesa through a        */
/* surfaceless EGL GLES3 context into an offscreen FBO that the GLES3     */
/* rasterizer uses as its "system" framebuffer, then (optionally) copy    */
/* each frame to the FPGA core's DDR3 double buffer as RGB565.            */
/*                                                                        */
/* Everything that is not rendering (windows, input dispatch, ...) is     */
/* inherited from DisplayServerHeadless.                                  */
/**************************************************************************/

#ifndef DISPLAY_SERVER_MISTER_H
#define DISPLAY_SERVER_MISTER_H

#include "servers/display_server_headless.h"

#if defined(GLES3_ENABLED) && defined(EGL_ENABLED)

#include "platform_gl.h"

class JoypadMister;

class DisplayServerMister : public DisplayServerHeadless {
	static Vector<String> get_rendering_drivers_func();
	static DisplayServer *create_func(const String &p_rendering_driver, WindowMode p_mode, VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, Context p_context, Error &r_error);

	Size2i size = Size2i(320, 240);

	EGLDisplay egl_display = EGL_NO_DISPLAY;
	EGLContext egl_context = EGL_NO_CONTEXT;
	EGLConfig egl_config = nullptr;

	// Offscreen render target used as GLES3::TextureStorage::system_fbo.
	uint32_t fbo = 0;
	uint32_t color_rb = 0;

	// FPGA DDR3 scanout (see donut.dodo SDL_mister_ddr.c for the contract).
	int mem_fd = -1;
	volatile uint8_t *ddr = nullptr;
	uint32_t frame_counter = 0;
	uint32_t active_buf = 0;
	uint8_t *rgba = nullptr;
	bool skip_readback = false;

	// Timing stats, printed every MISTER_STATS frames (0 = off).
	int stats_every = 0;
	uint32_t stat_frames = 0;
	uint64_t stat_start_us = 0;
	uint64_t stat_read_us = 0;
	uint64_t stat_conv_us = 0;

	JoypadMister *joypad = nullptr; // MISTER_JOY=1: DDR joystick words.

	Error _init_egl();
	void _ensure_fbo();
	void _init_ddr();
	void _present();

public:
	String get_name() const override { return "mister"; }

	int get_screen_count() const override { return 1; }
	Size2i screen_get_size(int p_screen = SCREEN_OF_MAIN_WINDOW) const override { return size; }
	Rect2i screen_get_usable_rect(int p_screen = SCREEN_OF_MAIN_WINDOW) const override { return Rect2i(Point2i(), size); }
	int screen_get_dpi(int p_screen = SCREEN_OF_MAIN_WINDOW) const override { return 96; }
	float screen_get_refresh_rate(int p_screen = SCREEN_OF_MAIN_WINDOW) const override { return 60.0; }

	Size2i window_get_size(WindowID p_window = MAIN_WINDOW_ID) const override { return size; }
	Size2i window_get_size_with_decorations(WindowID p_window = MAIN_WINDOW_ID) const override { return size; }
	WindowMode window_get_mode(WindowID p_window = MAIN_WINDOW_ID) const override { return WINDOW_MODE_FULLSCREEN; }
	bool window_can_draw(WindowID p_window = MAIN_WINDOW_ID) const override { return true; }
	// Main::iteration() only calls RenderingServer::draw() when this is true
	// (DisplayServerHeadless returns false).
	bool can_any_window_draw() const override { return true; }

	void gl_window_make_current(WindowID p_window_id) override;
	void release_rendering_thread() override;
	void swap_buffers() override;
	void process_events() override;

	static void register_mister_driver();

	DisplayServerMister(const String &p_rendering_driver, Error &r_error);
	~DisplayServerMister();
};

#endif // GLES3_ENABLED && EGL_ENABLED

#endif // DISPLAY_SERVER_MISTER_H
