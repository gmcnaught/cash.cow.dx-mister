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
// scanout starves the snapshot (donut.dodo glue.cpp pace_frame).
//
// MISTER_FABRIC_PACE=scanout (default): pace on the core's own scanout frame
// counter (scan_frame_cnt, RasterBackend_MFGPU_ScanoutRead: +1 per scanout
// frame boundary, period in clk_sys cycles; 59.9228 Hz measured). The core
// snapshots WORK at each boundary, and present() only publishes the batch (the
// fabric finishes it ~1-3 ms later). So a frame published at time t is shown at
// the first boundary after t + FABRIC_MARGIN, and the NEXT frame must not be
// published before that boundary, or it overwrites WORK first and the frame is
// never displayed. Before each publish we wait for that boundary. The engine's
// CPU work overlaps the wait (a late frame needs no wait at all), and a frame is
// never published twice within one boundary, so frames published == frames
// displayed. Boundary times come from the last observed counter change plus
// the period; the counter read stays authoritative. If the counter stops
// advancing (another core, a reader that never publishes it), fall back to the
// wall-clock pacer. MISTER_FABRIC_PACE=timer: wall clock at MISTER_FABRIC_FPS
// (default 59.92 Hz) after each present. =off: no pacing.
enum PaceMode { PACE_SCANOUT, PACE_TIMER, PACE_OFF };
PaceMode g_pace_mode = PACE_SCANOUT;
bool g_pace_env = false; // MISTER_FABRIC_PACE set: it wins over mf_set_pacing()
double g_pace_hz = 59.92;
uint64_t g_next_ns = 0;
uint64_t g_pace_sleep_ns = 0; // cumulative pacing wait, for the engine's frame log
// scanout model: boundary g_ref_cnt happened at ~g_ref_ns; period g_period_ns
bool g_have_ref = false;
uint32_t g_ref_cnt = 0;
uint64_t g_ref_ns = 0;
uint64_t g_period_ns = 16688200; // 1,642,740 clk_sys cycles at 98.4375 MHz
bool g_have_target = false;
uint32_t g_target_cnt = 0; // boundary the previous frame is shown at
uint64_t g_margin_ns = 3000000; // publish -> fabric done, worst case (MISTER_FABRIC_MARGIN_US)
const uint64_t SCAN_STALL_NS = 50000000ull; // ~3 periods without a boundary -> timer
const long SCAN_POLL_NS = 200000; // one uncached read per 0.2 ms while waiting

uint64_t now_ns() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

bool scan_count(uint32_t *c) {
	return RasterBackend_MFGPU_ScanoutRead(c, nullptr) != 0;
}

// Read the counter and keep the boundary model current.
bool scan_observe(uint32_t *c, uint64_t *t) {
	uint32_t cyc = 0;
	if (!RasterBackend_MFGPU_ScanoutRead(c, &cyc)) {
		return false;
	}
	*t = now_ns();
	if (cyc >= 492187 && cyc <= 4921875) { // sane band: 5-50 ms
		g_period_ns = (uint64_t)(cyc * (1e9 / 98437500.0));
	}
	if (!g_have_ref || *c != g_ref_cnt) {
		// A change seen now happened within the last poll interval; a change
		// first seen after a long gap is extrapolated from the old reference.
		if (g_have_ref && (int32_t)(*c - g_ref_cnt) > 0) {
			// The boundary happened at or before now: never adopt a future time.
			const int64_t predicted = (int64_t)g_ref_ns + (int64_t)(*c - g_ref_cnt) * (int64_t)g_period_ns;
			const int64_t age = (int64_t)*t - predicted;
			g_ref_ns = (age < 0 || age < (int64_t)SCAN_POLL_NS * 2) ? *t : (uint64_t)predicted;
		} else {
			g_ref_ns = *t;
		}
		g_ref_cnt = *c;
		g_have_ref = true;
	}
	return true;
}

void pace_timer() {
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
		g_pace_sleep_ns += now_ns() - now;
	}
	g_next_ns += interval;
}

// Scanout mode, before a publish: wait for the boundary the previous frame is shown at.
void pace_scanout_before_publish() {
	uint32_t c;
	uint64_t t;
	if (!g_have_target || !scan_observe(&c, &t)) {
		return;
	}
	if ((int32_t)(c - g_target_cnt) >= 0) {
		return; // the CPU work already covered the wait
	}
	const uint64_t t0 = t;
	const struct timespec poll = { 0, SCAN_POLL_NS };
	for (;;) {
		nanosleep(&poll, nullptr);
		if (!scan_observe(&c, &t)) {
			break;
		}
		if ((int32_t)(c - g_target_cnt) >= 0) {
			break;
		}
		if (t - t0 > SCAN_STALL_NS) {
			fprintf(stderr, "misterfabric: scanout counter stalled at %u - wall-clock pacing from now on\n", c);
			g_pace_mode = PACE_TIMER;
			break;
		}
	}
	g_pace_sleep_ns += now_ns() - t0;
}

// After a publish: the first boundary at least g_margin_ns later shows this frame.
void pace_scanout_after_publish() {
	uint32_t c;
	uint64_t t;
	if (!scan_observe(&c, &t)) {
		g_have_target = false;
		return;
	}
	const int64_t since_ref = (int64_t)(t + g_margin_ns) - (int64_t)g_ref_ns; // >= 0: ref_ns <= t
	g_target_cnt = g_ref_cnt + (uint32_t)(since_ref > 0 ? since_ref / (int64_t)g_period_ns : 0) + 1;
	g_have_target = true;
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
	const char *pm = getenv("MISTER_FABRIC_PACE");
	if (pm && !strcmp(pm, "timer")) {
		g_pace_mode = PACE_TIMER;
		g_pace_env = true;
	} else if (pm && !strcmp(pm, "off")) {
		g_pace_mode = PACE_OFF;
		g_pace_env = true;
	} else if (pm && !strcmp(pm, "scanout")) {
		g_pace_env = true;
	}
	const char *mg = getenv("MISTER_FABRIC_MARGIN_US");
	if (mg && *mg) {
		g_margin_ns = (uint64_t)atol(mg) * 1000u;
	}
	atexit(mf_shutdown);
	g_backend->frame_begin();
	g_open = true;
	fprintf(stderr, "misterfabric: backend=%s %dx%d pacing=%s\n", g_backend->name, g_surf.w, g_surf.h,
			g_pace_mode == PACE_SCANOUT ? "scanout counter" : g_pace_mode == PACE_TIMER ? "wall clock" : "off");
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
	if (g_pace_mode == PACE_SCANOUT) {
		pace_scanout_before_publish();
	}
	g_backend->present(&g_surf);
	g_backend->frame_begin();
	if (g_pace_mode == PACE_SCANOUT) {
		pace_scanout_after_publish();
	} else if (g_pace_mode == PACE_TIMER) {
		pace_timer();
	}
}

// Optional (not part of the ABI version check): cumulative pacing wait in ns.
extern "C" uint64_t mf_pace_sleep_ns(void) {
	return g_pace_sleep_ns;
}

// Optional: pacing from the engine's V-Sync mode. 0 = scanout counter (V-Sync
// on), 1 = wall clock at the scanout rate (V-Sync off: no vblank wait, but never
// faster than scanout, which would starve the snapshot), 2 = none.
// MISTER_FABRIC_PACE, when set, overrides this (measurement runs).
extern "C" void mf_set_pacing(int mode) {
	if (g_pace_env) {
		return;
	}
	g_pace_mode = mode == 1 ? PACE_TIMER : mode == 2 ? PACE_OFF : PACE_SCANOUT;
	g_have_target = false;
	g_next_ns = 0;
	fprintf(stderr, "misterfabric: pacing=%s (engine V-Sync mode)\n",
			g_pace_mode == PACE_SCANOUT ? "scanout counter" : g_pace_mode == PACE_TIMER ? "wall clock" : "off");
}

// Optional: the core's scanout frame counter (0 when unavailable).
extern "C" uint32_t mf_scan_count(void) {
	uint32_t c = 0;
	return g_open && scan_count(&c) ? c : 0;
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
