Vendored 2026-09-23 from ../donut.dodo-mister/src/vendor @ 7706bae (itself vendored from
gmloader-next/gmloader/mister and gmloader-next/3rdparty/mfgpu; TRILIST=10
protocol, matches the donutdodo/fb-320x240 Maldita fabric core).

Carried local edit (from donut.dodo): mfgpu/refmodel/blitter_ref.h
BLT_FB_WIDTH/HEIGHT = 320x240 (geometry contract with the core's
fpga/rtl/blitter_defs.vh FB_W/FB_H). Re-vendoring from gmloader-next resets it
to 288x216 silently.

Cash Cow DX edits (do not edit in place without recording the delta here):

2026-09-23 — CPU cost of the draw path, wire output unchanged. Proof: work/fabric_eq/
(replay_eq: base_vendor/ snapshot vs these sources, 3 seeds x 300 frames, ring bytes +
whole source heap + executed framebuffer identical; exhaustive_eq: the float
conversions below bit-exact against armhf glibc over their full domains).
- mfgpu/host/blt_emitter.c `emit()`: pack the 32-byte command on the stack, then write
  the ring as 8 aligned u32 stores (volatile; memcpy if the ring is unaligned). Was
  32 byte stores into the strongly-ordered /dev/mem ring.
- mister/raster_backend_convert.h: `rbc_lroundf` (inline, exact lroundf) replaces the
  8 libm lroundf calls per vertex; `bvtx_to_blt` split into `bvtx_rgba` +
  `bvtx_to_blt_with_rgba`; `RbcRgbaMemo`/`bvtx_rgba_memo` (one-entry bitwise memo of
  the colour word).
- mister/raster_backend_mfgpu.cpp: `mf_emit_group` uses the colour memo;
  `g_tex_hint`/`mf_tex_find` (validated direct-mapped lookup hint in front of the
  unchanged g_texcache linear scan, used by stage_texture and stage_texture_region;
  set on insert in mf_upload_and_cache); `mf_crop_rect` uses exact inline
  floor/ceil for its non-negative inputs.
