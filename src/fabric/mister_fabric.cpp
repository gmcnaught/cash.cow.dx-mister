// libmisterfabric: C ABI over the vendored RasterBackend. See mister_fabric.h.
#include "mister_fabric.h"

#include "raster_backend.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static_assert(sizeof(MFVtx) == sizeof(BVtx), "MFVtx must mirror BVtx");

namespace {

const RasterBackend *g_backend = nullptr;
RSurface g_surf{}; // fbo 0 = the fabric WORK surface; rgba backs the SW oracle only
bool g_open = false;

// The core snapshots WORK to scanout on vblank; submitting faster than the
// 59.92 Hz scanout starves the snapshot (donut.dodo glue.cpp pace_frame).
double g_pace_hz = 59.92;
uint64_t g_next_ns = 0;

uint64_t now_ns() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void pace() {
	if (g_pace_hz <= 0.0) {
		return;
	}
	const uint64_t interval = (uint64_t)(1e9 / g_pace_hz);
	const uint64_t now = now_ns();
	if (g_next_ns == 0 || now > g_next_ns + interval * 4) {
		g_next_ns = now + interval; // first frame, or fell far behind
		return;
	}
	if (g_next_ns > now) {
		uint64_t d = g_next_ns - now;
		struct timespec ts;
		ts.tv_sec = (time_t)(d / 1000000000ull);
		ts.tv_nsec = (long)(d % 1000000000ull);
		nanosleep(&ts, nullptr);
	}
	g_next_ns += interval;
}

} // namespace

extern "C" int mf_abi_version(void) {
	return MF_ABI_VERSION;
}

extern "C" int mf_open(void) {
	if (g_open) {
		return 1;
	}
	g_backend = RasterBackend_Select();
	if (!g_backend) {
		return 0;
	}
	g_surf.w = MISTER_WIDTH;
	g_surf.h = MISTER_HEIGHT;
	g_surf.fbo = 0;
	g_surf.rgba = (uint8_t *)calloc((size_t)g_surf.w * g_surf.h, 4);
	if (!g_surf.rgba) {
		return 0;
	}
	const char *fps = getenv("MISTER_FABRIC_FPS");
	if (fps && *fps) {
		g_pace_hz = atof(fps);
	}
	atexit(mf_shutdown);
	g_backend->frame_begin();
	g_open = true;
	fprintf(stderr, "misterfabric: backend=%s %dx%d pacing=%.2f Hz\n", g_backend->name, g_surf.w, g_surf.h, g_pace_hz);
	return 1;
}

extern "C" void mf_clear(uint8_t r, uint8_t g, uint8_t b) {
	if (g_open) {
		g_backend->clear(&g_surf, r, g, b, 255);
	}
}

extern "C" void mf_draw(const MFVtx *verts, int tri_count, const uint8_t *rgba, int w, int h,
		int opaque, int blend, uint32_t key) {
	if (!g_open || tri_count <= 0) {
		return;
	}
	RTexture tex{};
	tex.rgba = rgba;
	tex.w = w;
	tex.h = h;
	tex.nearest = 1;
	tex.valid = rgba != nullptr;
	tex.format = RTEX_RGBA8888;
	tex.opaque = opaque;
	g_backend->draw(&g_surf, (const BVtx *)verts, tri_count, &tex, (RBlend)blend, 0.0f, key);
}

extern "C" void mf_present(void) {
	if (!g_open) {
		return;
	}
	// present() closes the frame itself (frame_end + publish); calling
	// frame_end() again would submit a second, empty batch per frame.
	g_backend->present(&g_surf);
	g_backend->frame_begin();
	pace();
}

extern "C" void mf_tex_invalidate(uint32_t key) {
	if (g_open) {
		RasterBackend_MFGPU_InvalidateTex(key);
	}
}

extern "C" const uint8_t *mf_sw_frame(int *w, int *h) {
	if (!g_open || strcmp(g_backend->name, "sw") != 0) {
		return nullptr;
	}
	if (w) {
		*w = g_surf.w;
	}
	if (h) {
		*h = g_surf.h;
	}
	return g_surf.rgba;
}

extern "C" void mf_shutdown(void) {
	RasterBackend_MFGPU_Shutdown();
}
