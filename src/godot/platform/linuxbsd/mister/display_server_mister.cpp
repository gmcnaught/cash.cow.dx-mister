/**************************************************************************/
/*  display_server_mister.cpp                                             */
/**************************************************************************/
/* See display_server_mister.h.                                           */
/*                                                                        */
/* Environment:                                                           */
/*   MISTER_DDR_BASE=0x3BF40000  physical base of the core's video        */
/*                               region; unset = render + readback only   */
/*   MISTER_SKIP_READBACK=1      no glReadPixels (isolates render cost)   */
/*   MISTER_STATS=120            print timing every N frames              */
/*   MISTER_FABRIC=1             Tier 2: canvas draws go to the FPGA      */
/*                               blitter (drivers/gles3/mister_fabric_*)  */
/*   MISTER_JOY=1                joypad from DDR words (joypad_mister.h)  */
/*   MISTER_PIN_MAIN=<cpu>       pin the main thread to that CPU          */
/**************************************************************************/

#include "display_server_mister.h"
#include "joypad_mister.h"

#if defined(GLES3_ENABLED) && defined(EGL_ENABLED)

#include "core/os/os.h"
#include "drivers/gles3/mister_fabric_bridge.h"
#include "drivers/gles3/rasterizer_gles3.h"
#include "drivers/gles3/storage/texture_storage.h"

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

// MISTER_PIN_*=<cpu>: pin the calling thread to one CPU (PLAN §6.18: the
// launcher runs the engine on CPU1 and gives CPU0 to the main thread alone).
static void mister_pin_self(const char *p_env) {
	const char *e = getenv(p_env);
	if (e == nullptr || *e == '\0') {
		return;
	}
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(atoi(e), &set);
	if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) == 0) {
		print_line(vformat("MiSTer: %s -> CPU%d.", p_env, atoi(e)));
	}
}

// DDR3 layout shared by the MiSTer hybrid cores (control word, then two
// RGB565 buffers). The FPGA scans whichever buffer the control word names.
static const uint32_t MISTER_DDR_REGION = 0x00100000;
static const uint32_t MISTER_BUF0_OFFSET = 0x00000040;
static const uint32_t MISTER_BUF1_OFFSET = 0x00040040;

Vector<String> DisplayServerMister::get_rendering_drivers_func() {
	Vector<String> drivers;
	drivers.push_back("opengl3_es");
	return drivers;
}

DisplayServer *DisplayServerMister::create_func(const String &p_rendering_driver, WindowMode p_mode, VSyncMode p_vsync_mode, uint32_t p_flags, const Vector2i *p_position, const Vector2i &p_resolution, int p_screen, Context p_context, Error &r_error) {
	DisplayServer *ds = memnew(DisplayServerMister(p_rendering_driver, r_error));
	if (r_error != OK) {
		ERR_PRINT("MiSTer display server: EGL/GLES3 initialization failed.");
		memdelete(ds);
		return nullptr;
	}
	ds->window_set_vsync_mode(p_vsync_mode); // project setting / --disable-vsync
	return ds;
}

void DisplayServerMister::window_set_vsync_mode(VSyncMode p_vsync_mode, WindowID p_window) {
	vsync_mode = p_vsync_mode;
	MisterFabricBridge::set_pacing(p_vsync_mode == VSYNC_DISABLED ? 1 : 0);
}

void DisplayServerMister::register_mister_driver() {
	register_create_function("mister", create_func, get_rendering_drivers_func);
}

Error DisplayServerMister::_init_egl() {
	// No /dev/dri and no window system: Mesa resolves the default display to
	// its surfaceless platform (llvmpipe) when told to.
	setenv("EGL_PLATFORM", "surfaceless", 0);

	if (!gladLoaderLoadEGL(EGL_NO_DISPLAY)) {
		ERR_PRINT("MiSTer: cannot load libEGL.");
		return ERR_CANT_CREATE;
	}
	egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
	ERR_FAIL_COND_V_MSG(egl_display == EGL_NO_DISPLAY, ERR_CANT_CREATE, "MiSTer: eglGetDisplay failed.");
	EGLint major = 0, minor = 0;
	if (!eglInitialize(egl_display, &major, &minor)) {
		egl_display = EGL_NO_DISPLAY; // Nothing to tear down in the destructor.
		ERR_FAIL_V_MSG(ERR_CANT_CREATE, "MiSTer: eglInitialize failed.");
	}
	gladLoaderLoadEGL(egl_display); // Load display extensions.
	ERR_FAIL_COND_V_MSG(!eglBindAPI(EGL_OPENGL_ES_API), ERR_CANT_CREATE, "MiSTer: eglBindAPI(GLES) failed.");

	// EGL_SURFACE_TYPE defaults to EGL_WINDOW_BIT, which Mesa's surfaceless
	// platform never offers; we only need a context, so ask for pbuffer configs.
	const EGLint config_attribs[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_NONE
	};
	EGLint num_configs = 0;
	ERR_FAIL_COND_V_MSG(!eglChooseConfig(egl_display, config_attribs, &egl_config, 1, &num_configs) || num_configs < 1, ERR_CANT_CREATE, "MiSTer: no GLES3 EGL config.");

	const EGLint context_attribs[] = {
		EGL_CONTEXT_MAJOR_VERSION, 3,
		EGL_CONTEXT_MINOR_VERSION, 0,
		EGL_NONE
	};
	egl_context = eglCreateContext(egl_display, egl_config, EGL_NO_CONTEXT, context_attribs);
	ERR_FAIL_COND_V_MSG(egl_context == EGL_NO_CONTEXT, ERR_CANT_CREATE, "MiSTer: eglCreateContext(GLES 3.0) failed.");

	// EGL_KHR_surfaceless_context: current with no draw/read surface.
	ERR_FAIL_COND_V_MSG(!eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, egl_context), ERR_CANT_CREATE, "MiSTer: surfaceless eglMakeCurrent failed.");

	print_line(vformat("MiSTer: EGL %d.%d %s, surfaceless GLES 3.0 context, %dx%d.", major, minor, String(eglQueryString(egl_display, EGL_VENDOR)), size.x, size.y));
	return OK;
}

void DisplayServerMister::_ensure_fbo() {
	// GL entry points are loaded by RasterizerGLES3's constructor, which runs
	// after this display server exists, so create the FBO lazily on first use.
	if (fbo != 0 || glGenFramebuffers == nullptr) {
		return;
	}
	glGenRenderbuffers(1, &color_rb);
	glBindRenderbuffer(GL_RENDERBUFFER, color_rb);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, size.x, size.y);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, color_rb);
	GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	ERR_FAIL_COND_MSG(status != GL_FRAMEBUFFER_COMPLETE, vformat("MiSTer: offscreen FBO incomplete (0x%x).", status));
	GLES3::TextureStorage::system_fbo = fbo;
	print_line(vformat("MiSTer: offscreen FBO %d is the system framebuffer.", fbo));
}

void DisplayServerMister::_init_ddr() {
	const char *base_env = getenv("MISTER_DDR_BASE");
	if (base_env == nullptr || *base_env == '\0') {
		print_line("MiSTer: MISTER_DDR_BASE unset, frames are not sent to the FPGA.");
		return;
	}
	uint32_t base = (uint32_t)strtoul(base_env, nullptr, 0);
	mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
	ERR_FAIL_COND_MSG(mem_fd < 0, "MiSTer: cannot open /dev/mem (root required).");
	void *map = mmap(nullptr, MISTER_DDR_REGION, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, base);
	if (map == MAP_FAILED) {
		close(mem_fd);
		mem_fd = -1;
		ERR_FAIL_MSG(vformat("MiSTer: mmap of 0x%08x failed.", base));
	}
	ddr = (volatile uint8_t *)map;
	print_line(vformat("MiSTer: DDR scanout at 0x%08x, RGB565 %dx%d.", base, size.x, size.y));
}

void DisplayServerMister::_present() {
	if (skip_readback || fbo == 0) {
		return;
	}
	uint64_t t0 = OS::get_singleton()->get_ticks_usec();
	glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
	glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
	glBindFramebuffer(GL_READ_FRAMEBUFFER, GLES3::TextureStorage::system_fbo);
	uint64_t t1 = OS::get_singleton()->get_ticks_usec();

	if (ddr != nullptr) {
		// Write the inactive buffer, then publish it through the control word.
		// /dev/mem O_SYNC mapping keeps the stores in program order.
		uint32_t next = active_buf ^ 1;
		volatile uint16_t *dst = (volatile uint16_t *)(ddr + (next ? MISTER_BUF1_OFFSET : MISTER_BUF0_OFFSET));
		for (int y = 0; y < size.y; y++) {
			// GL rows are bottom-up.
			const uint8_t *src = rgba + (size.y - 1 - y) * size.x * 4;
			volatile uint16_t *row = dst + y * size.x;
			for (int x = 0; x < size.x; x++) {
				const uint8_t *p = src + x * 4;
				row[x] = (uint16_t)(((p[0] & 0xF8) << 8) | ((p[1] & 0xFC) << 3) | (p[2] >> 3));
			}
		}
		active_buf = next;
		frame_counter++;
		*(volatile uint32_t *)ddr = (frame_counter << 2) | active_buf;
	}
	uint64_t t2 = OS::get_singleton()->get_ticks_usec();

	if (stats_every > 0) {
		stat_read_us += t1 - t0;
		stat_conv_us += t2 - t1;
		if (++stat_frames >= (uint32_t)stats_every) {
			uint64_t now = t2;
			double secs = (now - stat_start_us) / 1e6;
			print_line(vformat("MISTER_STATS frames=%d fps=%.1f readback_ms=%.2f convert_ddr_ms=%.2f",
					stat_frames, stat_frames / secs, stat_read_us / 1000.0 / stat_frames, stat_conv_us / 1000.0 / stat_frames));
			stat_frames = 0;
			stat_read_us = 0;
			stat_conv_us = 0;
			stat_start_us = now;
		}
	}
}

void DisplayServerMister::gl_window_make_current(WindowID p_window_id) {
	// Called on whichever thread renders (main, or the separate render thread).
	if (eglGetCurrentContext() != egl_context) {
		eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, egl_context);
	}
	_ensure_fbo();
}

void DisplayServerMister::release_rendering_thread() {
	eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
}

void DisplayServerMister::swap_buffers() {
	if (MisterFabricBridge::active) {
		MisterFabricBridge::present(); // Tier 2: the FPGA blitter drew the frame.
	} else {
		_present(); // Tier 1: GL readback -> DDR.
	}
}

void DisplayServerMister::process_events() {
	if (joypad != nullptr) {
		joypad->poll();
	}
	DisplayServerHeadless::process_events(); // Flushes buffered input events.
}

DisplayServerMister::DisplayServerMister(const String &p_rendering_driver, Error &r_error) {
	r_error = ERR_UNAVAILABLE;
	if (p_rendering_driver != "opengl3_es") {
		ERR_PRINT(vformat("MiSTer display server supports only opengl3_es, not \"%s\".", p_rendering_driver));
		return;
	}
	r_error = _init_egl();
	if (r_error != OK) {
		return;
	}
	RasterizerGLES3::make_current(false); // GLES, not desktop GL.

	const char *skip = getenv("MISTER_SKIP_READBACK");
	skip_readback = skip != nullptr && *skip == '1';
	const char *stats = getenv("MISTER_STATS");
	stats_every = stats ? atoi(stats) : 0;
	stat_start_us = OS::get_singleton()->get_ticks_usec();
	rgba = (uint8_t *)memalloc(size.x * size.y * 4);
	// Tier 2 (MISTER_FABRIC=1) owns the frame; the Tier-1 DDR writer then stays off.
	if (!MisterFabricBridge::init()) {
		_init_ddr();
	}
	if (JoypadMister::is_enabled()) {
		joypad = memnew(JoypadMister);
	}
	// Last, after EGL/Mesa created their threads (they inherit the launcher's mask).
	mister_pin_self("MISTER_PIN_MAIN");
}

DisplayServerMister::~DisplayServerMister() {
	if (joypad != nullptr) {
		memdelete(joypad);
	}
	if (ddr != nullptr) {
		munmap((void *)ddr, MISTER_DDR_REGION);
	}
	if (mem_fd >= 0) {
		close(mem_fd);
	}
	if (rgba != nullptr) {
		memfree(rgba);
	}
	if (egl_display != EGL_NO_DISPLAY && eglMakeCurrent != nullptr) {
		eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		if (egl_context != EGL_NO_CONTEXT) {
			eglDestroyContext(egl_display, egl_context);
		}
		eglTerminate(egl_display);
	}
}

#endif // GLES3_ENABLED && EGL_ENABLED
