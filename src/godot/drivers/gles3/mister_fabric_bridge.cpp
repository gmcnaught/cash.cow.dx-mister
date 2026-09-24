/**************************************************************************/
/*  mister_fabric_bridge.cpp                                              */
/**************************************************************************/
/* See mister_fabric_bridge.h.                                            */
/*                                                                        */
/* Environment:                                                           */
/*   MISTER_FABRIC=1              enable (else stock GL path)             */
/*   MISTER_FABRIC_LIB=path       library (default libmisterfabric.so)    */
/*   MISTER_FABRIC_STATS=N        stats line every N frames               */
/*   GMLOADER_RASTER=mfgpu|sw     back-end (read by the library)          */
/*   MISTER_FABRIC_DUMP=N         sw back-end: write frame N as PPM       */
/**************************************************************************/

#include "mister_fabric_bridge.h"
#include "main/mister_framelog.h"

#ifdef GLES3_ENABLED

#include "core/string/print_string.h"
#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"
#include "storage/material_storage.h"
#include "storage/texture_storage.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

namespace MisterFabricBridge {

bool active = false;

namespace {

// Mirror of MFVtx in src/fabric/mister_fabric.h (ABI version 1).
struct MFVtx {
	float x, y;
	float u, v;
	float r, g, b, a;
};
enum { MF_BLEND_NONE = 0,
	MF_BLEND_ALPHA = 1,
	MF_BLEND_PREMULT = 2,
	MF_BLEND_ADD = 3 };
const int MF_ABI_VERSION = 1;

int (*p_abi_version)() = nullptr;
int (*p_open)() = nullptr;
void (*p_clear)(uint8_t, uint8_t, uint8_t) = nullptr;
void (*p_draw)(const MFVtx *, int, const uint8_t *, int, int, int, int, uint32_t) = nullptr;
void (*p_present)() = nullptr;
void (*p_tex_invalidate)(uint32_t) = nullptr;
const uint8_t *(*p_sw_frame)(int *, int *) = nullptr;
uint64_t (*p_pace_sleep_ns)() = nullptr; // optional
uint32_t (*p_scan_count)() = nullptr; // optional
void (*p_set_pacing)(int) = nullptr; // optional

struct TexEntry {
	Vector<uint8_t> rgba;
	Vector<uint8_t> white; // "flash to white" variant, built on first use
	int w = 0;
	int h = 0;
	bool opaque = false;
};
HashMap<uint32_t, TexEntry> textures;

// Untextured draws (ColorRect etc.) sample a 1x1 white texel.
const uint32_t WHITE_KEY = 0x7FFFFFF0u;
const uint8_t white_texel[4] = { 255, 255, 255, 255 };
// Flash variants use the GL id with the top bit set (donut.dodo convention).
const uint32_t FLASH_BIT = 0x80000000u;

Transform2D canvas_xform;
Color canvas_modulate(1, 1, 1, 1);
bool snap_vertices = false;
bool cleared_this_frame = false;

// Large-rect split (see emit_rect). The fabric target is the 320x240 WORK surface.
const float MISTER_FB_W = 320.0f;
const float MISTER_FB_H = 240.0f;
const float SPLIT_CELL_PX = 224.0f;
const int SPLIT_MAX_CELLS = 16; // per axis; a 16x16 grid covers 3584 px at 224 px/cell

int stats_every = 0;
int dump_frame = 0;
uint32_t frame_no = 0;
struct Stats {
	uint32_t rects = 0;
	uint32_t untextured = 0;
	uint32_t flash = 0;
	uint32_t rt_composites = 0;
	uint32_t missing_tex = 0;
	uint32_t premult = 0;
	uint32_t clears = 0;
	uint32_t split = 0; // rects split into cells
	uint32_t split_culled = 0; // off-screen cells dropped
	uint32_t polygons = 0; // TYPE_POLYGON commands drawn
	uint32_t missing_poly = 0; // polygon ids the bridge never saw created
	uint32_t unhandled[16] = {};
} stats;

template <typename T>
bool sym(void *p_lib, const char *p_name, T &r_fn) {
	r_fn = reinterpret_cast<T>(dlsym(p_lib, p_name));
	if (!r_fn) {
		ERR_PRINT(vformat("MiSTer fabric: missing symbol %s.", p_name));
	}
	return r_fn != nullptr;
}

// floorf without the libm call (ARMv7 has no vrint; snap floors 8 floats per rect).
// Exact for every input the snap can produce: |x| >= 2^23, inf and NaN are
// returned as-is (floorf returns them unchanged, NaN quieted, and x = v + 0.5 is
// never a signalling NaN), +/-0 likewise; otherwise truncate and step down for
// negative non-integers. Checked bitwise against glibc floorf over all 2^32
// inputs except signalling NaNs (cash.cow.dx-mister work/fabric_eq/floor_eq.c).
inline float floor_fast(float x) {
	if (!(Math::abs(x) < 8388608.0f) || x == 0.0f) {
		return x;
	}
	const float t = float(int32_t(x));
	return t > x ? t - 1.0f : t;
}

inline Vector2 xform_point(const float w[6], const Vector2 &v) {
	// world[] = columns x, y, origin (see _update_transform_2d_to_mat2x3).
	return Vector2(w[0] * v.x + w[2] * v.y + w[4], w[1] * v.x + w[3] * v.y + w[5]);
}

void write_ppm(const uint8_t *p_rgba, int p_w, int p_h, const char *p_path) {
	FILE *f = fopen(p_path, "wb");
	if (!f) {
		return;
	}
	fprintf(f, "P6\n%d %d\n255\n", p_w, p_h);
	for (int i = 0; i < p_w * p_h; i++) {
		fwrite(p_rgba + i * 4, 1, 3, f);
	}
	fclose(f);
	print_line(vformat("MiSTer fabric: wrote %s", p_path));
}


// ---- TYPE_POLYGON (StyleBoxFlat fills: the HUD combo and bonus-time bars) ----
// GLES3 uploads polygon vertices to GL buffers in request_polygon and keeps no
// CPU copy, so the bridge keeps one, keyed by polygon id.
struct PolyCPU {
	Vector<int> indices;
	Vector<Point2> points;
	Vector<Color> colors;
	Vector<Point2> uvs;
};
HashMap<uint64_t, PolyCPU> polygons;

} // namespace

bool init() {
	const char *en = getenv("MISTER_FABRIC");
	if (!en || *en != '1') {
		return false;
	}
	const char *lib_path = getenv("MISTER_FABRIC_LIB");
	void *lib = dlopen(lib_path && *lib_path ? lib_path : "libmisterfabric.so", RTLD_NOW | RTLD_LOCAL);
	if (!lib) {
		ERR_PRINT(vformat("MiSTer fabric: dlopen failed: %s", String(dlerror())));
		return false;
	}
	bool ok = sym(lib, "mf_abi_version", p_abi_version) && sym(lib, "mf_open", p_open) &&
			sym(lib, "mf_clear", p_clear) && sym(lib, "mf_draw", p_draw) &&
			sym(lib, "mf_present", p_present) && sym(lib, "mf_tex_invalidate", p_tex_invalidate) &&
			sym(lib, "mf_sw_frame", p_sw_frame);
	if (!ok) {
		return false;
	}
	p_pace_sleep_ns = (uint64_t(*)())dlsym(lib, "mf_pace_sleep_ns");
	p_scan_count = (uint32_t(*)())dlsym(lib, "mf_scan_count");
	p_set_pacing = (void (*)(int))dlsym(lib, "mf_set_pacing");
	if (p_abi_version() != MF_ABI_VERSION) {
		ERR_PRINT(vformat("MiSTer fabric: ABI %d, expected %d.", p_abi_version(), MF_ABI_VERSION));
		return false;
	}
	if (!p_open()) {
		ERR_PRINT("MiSTer fabric: mf_open failed.");
		return false;
	}
	const char *st = getenv("MISTER_FABRIC_STATS");
	stats_every = st ? atoi(st) : 0;
	const char *dp = getenv("MISTER_FABRIC_DUMP");
	dump_frame = dp ? atoi(dp) : 0;
	active = true;
	print_line("MiSTer fabric: canvas draws go to libmisterfabric; GL draws are skipped.");
	return true;
}

void texture_set(uint32_t p_gl_id, const Ref<Image> &p_image) {
	if (!active || p_image.is_null() || p_image->is_compressed()) {
		return;
	}
	Ref<Image> img = p_image;
	if (img->has_mipmaps() || img->get_format() != Image::FORMAT_RGBA8) {
		img = p_image->duplicate();
		img->clear_mipmaps();
		img->convert(Image::FORMAT_RGBA8);
	}
	TexEntry &e = textures[p_gl_id];
	e.w = img->get_width();
	e.h = img->get_height();
	e.rgba = img->get_data();
	e.white.clear();
	e.opaque = true;
	const uint8_t *px = e.rgba.ptr();
	for (int i = 0; i < e.w * e.h; i++) {
		if (px[i * 4 + 3] != 255) {
			e.opaque = false;
			break;
		}
	}
	p_tex_invalidate(p_gl_id);
	p_tex_invalidate(p_gl_id | FLASH_BIT);
}

void texture_free(uint32_t p_gl_id) {
	if (!active) {
		return;
	}
	textures.erase(p_gl_id);
	p_tex_invalidate(p_gl_id);
	p_tex_invalidate(p_gl_id | FLASH_BIT);
}

void begin_canvas(const Transform2D &p_canvas_transform, const Color &p_modulate, bool p_snap_vertices) {
	canvas_xform = p_canvas_transform;
	canvas_modulate = p_modulate;
	snap_vertices = p_snap_vertices;
}

void target_clear(const Color &p_color) {
	if (!active || cleared_this_frame) {
		return;
	}
	cleared_this_frame = true;
	stats.clears++;
	p_clear((uint8_t)CLAMP(p_color.r * 255.0f, 0.0f, 255.0f), (uint8_t)CLAMP(p_color.g * 255.0f, 0.0f, 255.0f),
			(uint8_t)CLAMP(p_color.b * 255.0f, 0.0f, 255.0f));
}

// What a draw samples and how it blends: the texture resolved exactly as
// RasterizerCanvasGLES3::_bind_canvas_texture does, the enemy flash material,
// and the blend mode. False = nothing to draw (render-target composite, or a
// texture the bridge never saw uploaded); the stats say which.
struct DrawSource {
	const uint8_t *rgba = nullptr;
	int tw = 1;
	int th = 1;
	bool opaque = true;
	uint32_t key = 0;
	int blend = 0;
};

bool resolve_source(RID p_texture, RID p_material, int p_blend_mode, DrawSource &r) {
	GLES3::TextureStorage *ts = GLES3::TextureStorage::get_singleton();

	// Resolve the texture exactly as RasterizerCanvasGLES3::_bind_canvas_texture does.
	const uint8_t *&rgba = r.rgba;
	int &tw = r.tw;
	int &th = r.th;
	bool &opaque = r.opaque;
	uint32_t &key = r.key;
	rgba = white_texel;
	tw = 1;
	th = 1;
	opaque = true;
	key = WHITE_KEY;
	TexEntry *entry = nullptr;
	if (p_texture.is_valid()) {
		GLES3::Texture *t = ts->get_texture(p_texture);
		if (!t) {
			GLES3::CanvasTexture *ct = ts->get_canvas_texture(p_texture);
			t = ct ? ts->get_texture(ct->diffuse) : nullptr;
		}
		if (t && t->render_target) {
			// The SubViewport's output drawn on the root canvas: its pixels are
			// already on the WORK surface (same 320x240 target, drawn first).
			stats.rt_composites++;
			return false;
		}
		if (t) {
			entry = textures.getptr(t->tex_id);
		}
		if (!entry) {
			stats.missing_tex++;
			return false;
		}
		key = t->tex_id;
		rgba = entry->rgba.ptr();
		tw = entry->w;
		th = entry->h;
		opaque = entry->opaque;
	} else {
		stats.untextured++;
	}

	// The game's one custom canvas shader: COLOR = mix(tex, white, opacity).
	if (entry && p_material.is_valid()) {
		// SNAME: a cached StringName; a string literal here built (hashed, locked,
		// interned) and released a StringName on every rect with a material.
		Variant op = GLES3::MaterialStorage::get_singleton()->material_get_param(p_material, SNAME("opacity"));
		if (op.get_type() == Variant::FLOAT && float(op) >= 0.5f) {
			if (entry->white.is_empty()) {
				entry->white = entry->rgba;
				uint8_t *w = entry->white.ptrw();
				for (int i = 0; i < tw * th; i++) {
					w[i * 4 + 0] = w[i * 4 + 1] = w[i * 4 + 2] = 255;
				}
			}
			rgba = entry->white.ptr();
			key |= FLASH_BIT;
			stats.flash++;
		}
	}

	int &blend = r.blend;
	blend = MF_BLEND_ALPHA;
	switch (p_blend_mode) {
		case GLES3::CanvasShaderData::BLEND_MODE_ADD:
			blend = MF_BLEND_ADD;
			break;
		case GLES3::CanvasShaderData::BLEND_MODE_PMALPHA:
			blend = MF_BLEND_PREMULT;
			stats.premult++;
			break;
		case GLES3::CanvasShaderData::BLEND_MODE_DISABLED:
			blend = MF_BLEND_NONE;
			break;
		default:
			break;
	}

	return true;
}

void emit_rect(const float p_world[6], const float p_src_rect[4], const float p_dst_rect[4],
		bool p_transpose, const float p_modulation[4], RID p_texture, int p_blend_mode, RID p_material) {
	DrawSource src;
	if (!resolve_source(p_texture, p_material, p_blend_mode, src)) {
		return;
	}
	const uint8_t *rgba = src.rgba;
	const int tw = src.tw, th = src.th;
	const bool opaque = src.opaque;
	const uint32_t key = src.key;
	const int blend = src.blend;

	// Vertex math of drivers/gles3/shaders/canvas.glsl (quad path):
	//   uv     = src.xy + |src.zw| * (transpose ? base.yx : base)
	//   vertex = dst.xy + |dst.zw| * (src.zw < 0 ? 1 - base : base)
	//   pixel  = canvas_transform * snap(world * vertex)
	const Color c = Color(p_modulation[0], p_modulation[1], p_modulation[2], p_modulation[3]) * canvas_modulate;
	// Vertex at rect parameter b in [0,1]^2 (b = base above; uv and position are linear in b).
	auto corner = [&](Vector2 b) -> MFVtx {
		const Vector2 bt = p_transpose ? Vector2(b.y, b.x) : b;
		Vector2 uv(p_src_rect[0] + Math::abs(p_src_rect[2]) * bt.x, p_src_rect[1] + Math::abs(p_src_rect[3]) * bt.y);
		Vector2 m(p_src_rect[2] < 0 ? 1.0f - b.x : b.x, p_src_rect[3] < 0 ? 1.0f - b.y : b.y);
		Vector2 v(p_dst_rect[0] + Math::abs(p_dst_rect[2]) * m.x, p_dst_rect[1] + Math::abs(p_dst_rect[3]) * m.y);
		v = xform_point(p_world, v);
		if (snap_vertices) {
			v += Vector2(0.5, 0.5);
			v = Vector2(floor_fast(v.x), floor_fast(v.y));
		}
		v = canvas_xform.xform(v);
		return { v.x, v.y, uv.x, uv.y, c.r, c.g, c.b, c.a };
	};
	static const Vector2 base[4] = { Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0) };
	MFVtx q[4];
	float lx = 1e30f, hx = -1e30f, ly = 1e30f, hy = -1e30f;
	for (int i = 0; i < 4; i++) {
		q[i] = corner(base[i]);
		lx = MIN(lx, q[i].x);
		hx = MAX(hx, q[i].x);
		ly = MIN(ly, q[i].y);
		hy = MAX(hy, q[i].y);
	}
	if (hx - lx <= SPLIT_CELL_PX && hy - ly <= SPLIT_CELL_PX) {
		const MFVtx tris[6] = { q[0], q[1], q[2], q[0], q[2], q[3] };
		p_draw(tris, 2, rgba, tw, th, opaque ? 1 : 0, blend, key);
		stats.rects++;
		return;
	}

	// Large rect (the scrolling level art is one 1472x240 sprite): split it into
	// cells of at most SPLIT_CELL_PX on screen and drop cells wholly off-screen.
	// The blitter's triangle setup is validated up to an area x2 of ~1.7e7 in
	// 12.4 units (blt_tri_setup.sv); a 1472x240 half-rect is 9.0e7, and its first
	// triangle rendered at half brightness on the fabric (PLAN §6.11). A 224 px
	// cell keeps every triangle at <= 224*224*256 = 1.3e7.
	const int nx = MIN(MAX(1, (int)Math::ceil((hx - lx) / SPLIT_CELL_PX)), SPLIT_MAX_CELLS);
	const int ny = MIN(MAX(1, (int)Math::ceil((hy - ly) / SPLIT_CELL_PX)), SPLIT_MAX_CELLS);
	MFVtx tris[SPLIT_MAX_CELLS * SPLIT_MAX_CELLS * 6];
	int ntri = 0;
	for (int j = 0; j < ny; j++) {
		for (int i = 0; i < nx; i++) {
			const float b0x = float(i) / nx, b1x = float(i + 1) / nx;
			const float b0y = float(j) / ny, b1y = float(j + 1) / ny;
			const MFVtx cq[4] = { corner(Vector2(b0x, b0y)), corner(Vector2(b0x, b1y)), corner(Vector2(b1x, b1y)), corner(Vector2(b1x, b0y)) };
			float clx = 1e30f, chx = -1e30f, cly = 1e30f, chy = -1e30f;
			for (int k = 0; k < 4; k++) {
				clx = MIN(clx, cq[k].x);
				chx = MAX(chx, cq[k].x);
				cly = MIN(cly, cq[k].y);
				chy = MAX(chy, cq[k].y);
			}
			if (chx <= 0 || clx >= MISTER_FB_W || chy <= 0 || cly >= MISTER_FB_H) {
				stats.split_culled++;
				continue;
			}
			MFVtx *t = &tris[ntri * 3];
			t[0] = cq[0];
			t[1] = cq[1];
			t[2] = cq[2];
			t[3] = cq[0];
			t[4] = cq[2];
			t[5] = cq[3];
			ntri += 2;
		}
	}
	if (ntri > 0) {
		p_draw(tris, ntri, rgba, tw, th, opaque ? 1 : 0, blend, key);
	}
	stats.rects++;
	stats.split++;
}

void polygon_created(uint64_t p_id, const Vector<int> &p_indices, const Vector<Point2> &p_points, const Vector<Color> &p_colors, const Vector<Point2> &p_uvs) {
	if (!active) {
		return;
	}
	PolyCPU &pc = polygons[p_id];
	pc.indices = p_indices;
	pc.points = p_points;
	pc.colors = p_colors;
	pc.uvs = p_uvs;
}

void polygon_freed(uint64_t p_id) {
	if (active) {
		polygons.erase(p_id);
	}
}

// One TYPE_POLYGON command, as the canvas shader's attribute path draws it:
// pixel = canvas_transform * snap(world * point); color = vertex color (or the
// single color, or white) * modulate; uv per vertex (normalized) or 0.
void emit_polygon(const float p_world[6], uint64_t p_polygon_id, const float p_modulation[4], RID p_texture, int p_blend_mode, RID p_material) {
	const PolyCPU *pc = polygons.getptr(p_polygon_id);
	if (pc == nullptr) {
		stats.missing_poly++;
		return;
	}
	DrawSource src;
	if (!resolve_source(p_texture, p_material, p_blend_mode, src)) {
		return;
	}
	const int n = pc->points.size();
	const bool per_vertex_color = pc->colors.size() == n;
	const Color single = pc->colors.size() == 1 ? pc->colors[0] : Color(1, 1, 1, 1);
	const bool has_uv = pc->uvs.size() == n;
	const Color mod = Color(p_modulation[0], p_modulation[1], p_modulation[2], p_modulation[3]) * canvas_modulate;
	auto vtx = [&](int i) -> MFVtx {
		Vector2 v = xform_point(p_world, pc->points[i]);
		if (snap_vertices) {
			v += Vector2(0.5, 0.5);
			v = Vector2(floor_fast(v.x), floor_fast(v.y));
		}
		v = canvas_xform.xform(v);
		const Color c = (per_vertex_color ? pc->colors[i] : single) * mod;
		const Vector2 uv = has_uv ? pc->uvs[i] : Vector2();
		return { v.x, v.y, uv.x, uv.y, c.r, c.g, c.b, c.a };
	};
	// No index buffer: GL_TRIANGLES over the points in order.
	const int count = pc->indices.is_empty() ? (n / 3) * 3 : pc->indices.size() - pc->indices.size() % 3;
	if (count <= 0) {
		return;
	}
	LocalVector<MFVtx> tris;
	tris.resize(count);
	for (int i = 0; i < count; i++) {
		const int idx = pc->indices.is_empty() ? i : pc->indices[i];
		if (idx < 0 || idx >= n) {
			return; // Malformed: draw nothing rather than read out of range.
		}
		tris[i] = vtx(idx);
	}
	p_draw(tris.ptr(), count / 3, src.rgba, src.tw, src.th, src.opaque ? 1 : 0, src.blend, src.key);
	stats.polygons++;
}

void set_pacing(int p_mode) {
	if (active && p_set_pacing) {
		p_set_pacing(p_mode);
	}
}

void note_unhandled(int p_command_type) {
	stats.unhandled[p_command_type & 15]++;
}

void present() {
	if (!active) {
		return;
	}
	const uint64_t mf_t = MisterFramelog::enabled ? MisterFramelog::now_us() : 0;
	const uint64_t mf_pace = (MisterFramelog::enabled && p_pace_sleep_ns) ? p_pace_sleep_ns() : 0;
	p_present();
	if (MisterFramelog::enabled) {
		MisterFramelog::present_us += MisterFramelog::now_us() - mf_t;
		if (p_pace_sleep_ns) {
			MisterFramelog::pace_us += (p_pace_sleep_ns() - mf_pace) / 1000;
		}
		MisterFramelog::scan = p_scan_count ? p_scan_count() : 0;
	}
	frame_no++;
	cleared_this_frame = false;

	if (dump_frame > 0 && frame_no == (uint32_t)dump_frame) {
		int w = 0, h = 0;
		const uint8_t *px = p_sw_frame(&w, &h);
		if (px) {
			write_ppm(px, w, h, "/tmp/mister_fabric_frame.ppm");
		}
	}
	if (stats_every > 0 && frame_no % stats_every == 0) {
		String un;
		for (int i = 0; i < 16; i++) {
			if (stats.unhandled[i]) {
				un += vformat(" t%d=%d", i, stats.unhandled[i]);
			}
		}
		print_line(vformat("MISTER_FABRIC frames=%d rects/f=%.1f untextured=%d flash=%d rt_composite=%d missing_tex=%d premult=%d clears=%d split=%d split_culled=%d poly=%d missing_poly=%d textures=%d unhandled:%s",
				stats_every, float(stats.rects) / stats_every, stats.untextured, stats.flash, stats.rt_composites,
				stats.missing_tex, stats.premult, stats.clears, stats.split, stats.split_culled, stats.polygons, stats.missing_poly, textures.size(), un.is_empty() ? String(" none") : un));
		stats = Stats();
	}
}

} // namespace MisterFabricBridge

#endif // GLES3_ENABLED
