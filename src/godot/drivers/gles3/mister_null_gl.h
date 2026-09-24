/**************************************************************************/
/*  mister_null_gl.h                                                      */
/**************************************************************************/
/* MiSTer port: a GL ES 3.0 implementation that does nothing, for fabric     */
/* mode. The FPGA blitter draws every frame from CPU-side data captured by   */
/* mister_fabric_bridge (textures as Images, canvas commands), so GL output  */
/* is never displayed; Mesa/llvmpipe was only initialised, compiling shaders */
/* and holding texture copies. With the null GL no EGL or Mesa library is    */
/* loaded. Queries return what Mesa llvmpipe (21.3.9) answered on the        */
/* device (MISTER_BOOTLOG "gl" lines); object names are unique counters;     */
/* compile/link succeed; mapped buffers are scratch memory; read-backs       */
/* leave the caller's memory untouched.                                      */
/* MISTER_NULL_GL=0 restores EGL + Mesa (not in the release bundle:          */
/* point LD_LIBRARY_PATH and LIBGL_DRIVERS_PATH at a Mesa build).            */
/* Used only with MISTER_FABRIC=1.                                           */
/**************************************************************************/

#pragma once

namespace MisterNullGL {

// MISTER_FABRIC=1 and MISTER_NULL_GL not "0".
bool enabled();
// GLADloadfunc: the null implementation of a GL entry point.
void *get_proc(const char *p_name);

} // namespace MisterNullGL
