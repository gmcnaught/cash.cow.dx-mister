/**************************************************************************/
/*  mister_fabric_bridge.h                                                */
/**************************************************************************/
/* MiSTer Tier 2: route the GLES3 canvas renderer's 2D draws to the FPGA  */
/* blitter through libmisterfabric.so (dlopened; see src/fabric in the    */
/* cash.cow.dx-mister project). Active only when MISTER_FABRIC=1 and the  */
/* library loads; otherwise every entry point is a no-op and the stock GL */
/* path runs unchanged.                                                   */
/**************************************************************************/

#ifndef MISTER_FABRIC_BRIDGE_H
#define MISTER_FABRIC_BRIDGE_H

#ifdef GLES3_ENABLED

#include "core/io/image.h"
#include "core/math/color.h"
#include "core/math/transform_2d.h"
#include "core/templates/rid.h"

namespace MisterFabricBridge {

// Loads the library and opens the back-end once (called by DisplayServerMister).
bool init();
// True when fabric rendering replaces GL draws.
extern bool active;

// Texture pixels, captured at GL upload time (mip 0, converted to RGBA8).
void texture_set(uint32_t p_gl_id, const Ref<Image> &p_image);
void texture_free(uint32_t p_gl_id);

// Per canvas_render_items() call: the layer's canvas transform, canvas
// modulate and vertex snapping, as the canvas shader applies them.
void begin_canvas(const Transform2D &p_canvas_transform, const Color &p_modulate, bool p_snap_vertices);
// A render target is being drawn; only the frame's first clear reaches the
// fabric (the SubViewport renders before the root, onto the same WORK surface).
void target_clear(const Color &p_color);

// One TYPE_RECT instance, exactly as RasterizerCanvasGLES3 recorded it.
void emit_rect(const float p_world[6], const float p_src_rect[4], const float p_dst_rect[4],
		bool p_transpose, const float p_modulation[4], RID p_texture, int p_blend_mode, RID p_material);
// TYPE_POLYGON: the bridge keeps a CPU copy of each polygon (GLES3 keeps only
// GL buffers) and draws it as triangles.
void polygon_created(uint64_t p_id, const Vector<int> &p_indices, const Vector<Point2> &p_points, const Vector<Color> &p_colors, const Vector<Point2> &p_uvs);
void polygon_freed(uint64_t p_id);
void emit_polygon(const float p_world[6], uint64_t p_polygon_id, const float p_modulation[4], RID p_texture, int p_blend_mode, RID p_material);
// Command types not translated yet (counted for the stats line).
void note_unhandled(int p_command_type);

// Close the frame: submit to the fabric, pace to scanout, print stats.
void present();

} // namespace MisterFabricBridge

#endif // GLES3_ENABLED

#endif // MISTER_FABRIC_BRIDGE_H
