/* libmisterfabric: a plain C ABI over the vendored RasterBackend (mfgpu FPGA
 * blitter, or the software rasterizer as an oracle), for Godot 4.3's GLES3
 * canvas renderer to dlopen. The engine side never includes vendored headers.
 *
 * Coordinates: x/y are framebuffer pixels (320x240, y down); u/v are
 * normalized 0..1 over the texture passed with the draw; r/g/b/a are 0..1
 * per-vertex modulate. Texture pixels are RGBA8888, top row first, and must
 * stay valid until mf_tex_invalidate(key) (the back-end stages lazily).
 */
#ifndef MISTER_FABRIC_H
#define MISTER_FABRIC_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MFVtx {
	float x, y;
	float u, v;
	float r, g, b, a;
} MFVtx;

enum MFBlend {
	MF_BLEND_NONE = 0, /* opaque copy */
	MF_BLEND_ALPHA = 1, /* source-over (fabric: colour key + vertex alpha) */
	MF_BLEND_PREMULT = 2, /* unsupported on the fabric: dropped */
	MF_BLEND_ADD = 3,
};

#define MF_ABI_VERSION 1

/* Returns MF_ABI_VERSION. */
int mf_abi_version(void);
/* Select the back-end (GMLOADER_RASTER=mfgpu|sw) and open the first frame.
   Returns 1 on success. Framebuffer size is fixed by the core (320x240). */
int mf_open(void);
/* Clear the frame to an opaque colour (0..255). */
void mf_clear(uint8_t r, uint8_t g, uint8_t b);
/* Draw tri_count triangles (3 vertices each). */
void mf_draw(const MFVtx *verts, int tri_count, const uint8_t *rgba, int w, int h,
		int opaque, int blend, uint32_t key);
/* Close and submit the frame, open the next one, pace to scanout (59.92 Hz
   unless MISTER_FABRIC_FPS overrides; 0 = unpaced). */
void mf_present(void);
/* Forget any staged copy of texture `key` (re-upload or delete). */
void mf_tex_invalidate(uint32_t key);
/* Optional: cumulative frame-pacing sleep inside mf_present, in ns. */
uint64_t mf_pace_sleep_ns(void);
/* Optional: the core's scanout frame counter (+1 per scanout frame), 0 if unavailable. */
uint32_t mf_scan_count(void);
/* Optional: 0 = pace on the scanout counter, 1 = wall clock at the scanout rate, 2 = none. */
void mf_set_pacing(int mode);
/* SW back-end only: the RGBA8888 frame it rendered (NULL on mfgpu). */
const uint8_t *mf_sw_frame(int *w, int *h);
/* Quiesce the fabric for the next engine (also runs atexit). */
void mf_shutdown(void);

#ifdef __cplusplus
}
#endif
#endif
