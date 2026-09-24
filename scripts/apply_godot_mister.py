#!/usr/bin/env python3
"""Apply the MiSTer platform additions to a godot-4.3-stable tree (idempotent).

  scripts/apply_godot_mister.py work/src/godot-4.3-stable

- copies src/godot/** into the tree
- adds platform/linuxbsd/mister/*.cpp to platform/linuxbsd/SCsub
- registers the "mister" display driver in platform/linuxbsd/os_linuxbsd.cpp
- registers the "MiSTer" audio driver and lets MISTER_JOY=1 replace JoypadLinux
"""
import pathlib, shutil, sys

root = pathlib.Path(__file__).resolve().parent.parent
tree = pathlib.Path(sys.argv[1]).resolve()
src = root / "src" / "godot"

for f in src.rglob("*"):
    if f.is_file():
        dst = tree / f.relative_to(src)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, dst)
        print("copied", dst.relative_to(tree))


def edit(rel, marker, old, new):
    p = tree / rel
    s = p.read_text()
    if marker in s:
        print("already applied:", rel)
        return
    if old not in s:
        sys.exit(f"anchor not found in {rel}: {old!r}")
    p.write_text(s.replace(old, new, 1))
    print("patched", rel)


edit("platform/linuxbsd/SCsub", "mister/display_server_mister.cpp",
     'if env["x11"]:\n    common_linuxbsd += SConscript("x11/SCsub")\n',
     'if env["opengl3"]:\n    common_linuxbsd.append("mister/display_server_mister.cpp")\n\n'
     'if env["x11"]:\n    common_linuxbsd += SConscript("x11/SCsub")\n')

edit("platform/linuxbsd/os_linuxbsd.cpp", "mister/display_server_mister.h",
     '#include "core/io/certs_compressed.gen.h"\n',
     '#include "core/io/certs_compressed.gen.h"\n#include "mister/display_server_mister.h"\n')

# Cortex-A9 has no hardware integer divide, and 32-bit GCC has no __int128, so
# upstream fastmod() falls back to `n % d` -> __aeabi_uidivmod on every
# HashMap/HashSet probe (~11% of gameplay CPU under perf). Compute the same
# high 32 bits of the 96-bit product lowbits*d with 32x32->64 multiplies:
#   lowbits = hi*2^32 + lo  =>  (lowbits*d) >> 64 == (hi*d + ((lo*d) >> 32)) >> 32
# (the inner sum is < 2^64, and the identity is exact for floor division).
edit("core/templates/hashfuncs.h", "MISTER: 32-bit fastmod",
     '#else\n\t// Fallback to the slower method if no 128-bit unsigned integer type is available.\n\treturn n % d;\n#endif // __SIZEOF_INT128__',
     '#else\n\t// MISTER: 32-bit fastmod without __int128 (no hardware divide on Cortex-A9).\n'
     '\tconst uint64_t lowbits = c * n;\n'
     '\tconst uint64_t lo_d = (uint64_t)(uint32_t)lowbits * d;\n'
     '\tconst uint64_t hi_d = (uint64_t)(uint32_t)(lowbits >> 32) * d;\n'
     '\treturn static_cast<uint32_t>((hi_d + (lo_d >> 32)) >> 32);\n'
     '#endif // __SIZEOF_INT128__')

# ---- Tier 2: canvas draws -> FPGA blitter (drivers/gles3/mister_fabric_bridge.*) ----
RC = "drivers/gles3/rasterizer_canvas_gles3.cpp"
edit(RC, '#include "mister_fabric_bridge.h"',
     '#include "rasterizer_canvas_gles3.h"\n',
     '#include "rasterizer_canvas_gles3.h"\n#include "mister_fabric_bridge.h"\n')
edit(RC, "MisterFabricBridge::begin_canvas",
     '\t\tstate_buffer.use_pixel_snap = p_snap_2d_vertices_to_pixel;\n',
     '\t\tstate_buffer.use_pixel_snap = p_snap_2d_vertices_to_pixel;\n'
     '\t\tMisterFabricBridge::begin_canvas(p_canvas_transform, p_modulate, p_snap_2d_vertices_to_pixel);\n')
edit(RC, "MisterFabricBridge::target_clear(col)",
     '\tif (render_target && render_target->clear_requested) {\n\t\tconst Color &col = render_target->clear_color;\n',
     '\tif (render_target && render_target->clear_requested) {\n\t\tconst Color &col = render_target->clear_color;\n'
     '\t\tMisterFabricBridge::target_clear(col);\n')
# Fabric mode: nothing is drawn into the GL render targets, so don't pay Mesa
# for clearing them (llvmpipe memset, ~20% of CPU across two threads).
edit(RC, "MISTER: skip the GL clear",
     '\t\tglClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);\n\t\trender_target->clear_requested = false;\n',
     '\t\tif (!MisterFabricBridge::active) { // MISTER: skip the GL clear, the fabric owns the frame.\n'
     '\t\t\tglClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);\n\t\t}\n'
     '\t\trender_target->clear_requested = false;\n')

edit(RC, "MisterFabricBridge::note_unhandled",
     '\t\tswitch (c->type) {\n\t\t\tcase Item::Command::TYPE_RECT: {\n',
     '\t\tif (MisterFabricBridge::active && c->type != Item::Command::TYPE_RECT && c->type != Item::Command::TYPE_TRANSFORM &&\n'
     '\t\t\t\tc->type != Item::Command::TYPE_CLIP_IGNORE && c->type != Item::Command::TYPE_ANIMATION_SLICE) {\n'
     '\t\t\tMisterFabricBridge::note_unhandled(int(c->type));\n\t\t}\n\n'
     '\t\tswitch (c->type) {\n\t\t\tcase Item::Command::TYPE_RECT: {\n')
edit(RC, "MisterFabricBridge::emit_rect",
     '\t\t\t\tstate.instance_data_array[r_index].dst_rect[3] = dst_rect.size.height;\n\n\t\t\t\t_add_to_batch(r_index, r_batch_broken);\n',
     '\t\t\t\tstate.instance_data_array[r_index].dst_rect[3] = dst_rect.size.height;\n\n'
     '\t\t\t\tif (MisterFabricBridge::active) {\n'
     '\t\t\t\t\tconst InstanceData &mfi = state.instance_data_array[r_index];\n'
     '\t\t\t\t\tconst Batch &mfb = state.canvas_instance_batches[state.current_batch_index];\n'
     '\t\t\t\t\tMisterFabricBridge::emit_rect(mfi.world, mfi.src_rect, mfi.dst_rect, (mfi.flags & FLAGS_TRANSPOSE_RECT) != 0,\n'
     '\t\t\t\t\t\t\tmfi.modulation, rect->texture, int(blend_mode), mfb.material);\n'
     '\t\t\t\t}\n\n'
     '\t\t\t\t_add_to_batch(r_index, r_batch_broken);\n')
# Fabric mode: the draws already went out while recording; no GL upload or replay.
edit(RC, "MISTER: draws already went to the fabric",
     '\t// Copy over all data needed for rendering.\n\tglBindBuffer(GL_ARRAY_BUFFER, state.canvas_instance_data_buffers[state.current_data_buffer_index].instance_buffers[state.current_instance_buffer_index]);\n',
     '\tif (MisterFabricBridge::active) {\n'
     '\t\t// MISTER: draws already went to the fabric in _record_item_commands.\n'
     '\t\tstate.current_batch_index = 0;\n\t\tstate.canvas_instance_batches.clear();\n\t\treturn;\n\t}\n\n'
     '\t// Copy over all data needed for rendering.\n\tglBindBuffer(GL_ARRAY_BUFFER, state.canvas_instance_data_buffers[state.current_data_buffer_index].instance_buffers[state.current_instance_buffer_index]);\n')
edit(RC, "MISTER: no GL instance buffers in fabric mode",
     '\tif (r_index + state.last_item_index >= data.max_instances_per_buffer) {\n'
     '\t\t// Copy over all data needed for rendering right away\n'
     '\t\t// then go back to recording item commands.\n',
     '\tif (r_index + state.last_item_index >= data.max_instances_per_buffer && MisterFabricBridge::active) {\n'
     '\t\t// MISTER: no GL instance buffers in fabric mode; just recycle the CPU array.\n'
     '\t\tr_index = 0;\n\t\tstate.last_item_index = 0;\n\t\tr_batch_broken = false;\n\t\t_new_batch(r_batch_broken);\n'
     '\t\tstate.canvas_instance_batches[state.current_batch_index].start = 0;\n\t\treturn;\n\t}\n'
     '\tif (r_index + state.last_item_index >= data.max_instances_per_buffer) {\n'
     '\t\t// Copy over all data needed for rendering right away\n'
     '\t\t// then go back to recording item commands.\n')

TS = "drivers/gles3/storage/texture_storage.cpp"
edit(TS, '#include "../mister_fabric_bridge.h"',
     '#include "texture_storage.h"\n',
     '#include "texture_storage.h"\n#include "../mister_fabric_bridge.h"\n')
edit(TS, "MisterFabricBridge::texture_set",
     '\tVector<uint8_t> read = img->get_data();\n\n\tglActiveTexture(GL_TEXTURE0);\n\tglBindTexture(texture->target, texture->tex_id);\n',
     '\tVector<uint8_t> read = img->get_data();\n\n'
     '\tif (MisterFabricBridge::active && p_layer == 0 && !compressed) {\n'
     '\t\tMisterFabricBridge::texture_set(texture->tex_id, img);\n\t}\n\n'
     '\tglActiveTexture(GL_TEXTURE0);\n\tglBindTexture(texture->target, texture->tex_id);\n')
edit(TS, "MisterFabricBridge::texture_free",
     '\tERR_FAIL_COND(t->is_render_target);\n\n\tif (t->canvas_texture) {\n\t\tmemdelete(t->canvas_texture);\n\t}\n',
     '\tERR_FAIL_COND(t->is_render_target);\n\n'
     '\tif (!t->is_proxy && t->tex_id != 0) {\n\t\tMisterFabricBridge::texture_free(t->tex_id); // Proxies share the GL id.\n\t}\n\n'
     '\tif (t->canvas_texture) {\n\t\tmemdelete(t->canvas_texture);\n\t}\n')
edit(TS, "MisterFabricBridge::target_clear(rt->clear_color)",
     '\tif (!rt->clear_requested) {\n\t\treturn;\n\t}\n\tglBindFramebuffer(GL_FRAMEBUFFER, rt->fbo);\n',
     '\tif (!rt->clear_requested) {\n\t\treturn;\n\t}\n'
     '\tMisterFabricBridge::target_clear(rt->clear_color);\n'
     '\tglBindFramebuffer(GL_FRAMEBUFFER, rt->fbo);\n')
edit(TS, "MISTER: no GL clear, the fabric owns the frame",
     '\tMisterFabricBridge::target_clear(rt->clear_color);\n\tglBindFramebuffer(GL_FRAMEBUFFER, rt->fbo);\n',
     '\tMisterFabricBridge::target_clear(rt->clear_color);\n'
     '\tif (MisterFabricBridge::active) {\n\t\trt->clear_requested = false; // MISTER: no GL clear, the fabric owns the frame.\n\t\treturn;\n\t}\n'
     '\tglBindFramebuffer(GL_FRAMEBUFFER, rt->fbo);\n')

RG = "drivers/gles3/rasterizer_gles3.cpp"
edit(RG, '#include "mister_fabric_bridge.h"',
     '#include "rasterizer_gles3.h"\n',
     '#include "rasterizer_gles3.h"\n#include "mister_fabric_bridge.h"\n')
edit(RG, "MISTER: the fabric owns the frame",
     'void RasterizerGLES3::blit_render_targets_to_screen(DisplayServer::WindowID p_screen, const BlitToScreen *p_render_targets, int p_amount) {\n',
     'void RasterizerGLES3::blit_render_targets_to_screen(DisplayServer::WindowID p_screen, const BlitToScreen *p_render_targets, int p_amount) {\n'
     '\tif (MisterFabricBridge::active) {\n\t\treturn; // MISTER: the fabric owns the frame.\n\t}\n')

edit("platform/linuxbsd/os_linuxbsd.cpp", "register_mister_driver",
     '#ifdef X11_ENABLED\n\tDisplayServerX11::register_x11_driver();\n#endif\n',
     '#if defined(GLES3_ENABLED) && defined(EGL_ENABLED)\n\tDisplayServerMister::register_mister_driver();\n#endif\n\n'
     '#ifdef X11_ENABLED\n\tDisplayServerX11::register_x11_driver();\n#endif\n')

# ---- Audio (DDR ring) and input (DDR joystick words) ----
edit("platform/linuxbsd/SCsub", "mister/audio_driver_mister.cpp",
     'if env["x11"]:\n    common_linuxbsd += SConscript("x11/SCsub")\n',
     'common_linuxbsd += ["mister/audio_driver_mister.cpp", "mister/joypad_mister.cpp"]\n\n'
     'if env["x11"]:\n    common_linuxbsd += SConscript("x11/SCsub")\n')
OL = "platform/linuxbsd/os_linuxbsd.h"
edit(OL, "mister/audio_driver_mister.h",
     '#include "joypad_linux.h"\n',
     '#include "joypad_linux.h"\n#include "mister/audio_driver_mister.h"\n#include "mister/joypad_mister.h"\n')
edit(OL, "AudioDriverMister driver_mister",
     '#ifdef ALSA_ENABLED\n\tAudioDriverALSA driver_alsa;\n',
     '\tAudioDriverMister driver_mister;\n\n#ifdef ALSA_ENABLED\n\tAudioDriverALSA driver_alsa;\n')
OC = "platform/linuxbsd/os_linuxbsd.cpp"
# First in the list: on the DE10-Nano it is the only driver that can work; off
# MiSTer its init fails (no /dev/mem ring) and the manager moves on.
edit(OC, "add_driver(&driver_mister)",
     '#ifdef PULSEAUDIO_ENABLED\n\tAudioDriverManager::add_driver(&driver_pulseaudio);\n#endif\n',
     '\tAudioDriverManager::add_driver(&driver_mister);\n\n'
     '#ifdef PULSEAUDIO_ENABLED\n\tAudioDriverManager::add_driver(&driver_pulseaudio);\n#endif\n')
# MiSTer holds an exclusive evdev grab on the real pad, so JoypadLinux would
# add a joypad that never reports (donut.dodo PLAN: same trap in SDL).
edit(OC, "MISTER: DDR joystick replaces JoypadLinux",
     '#ifdef JOYDEV_ENABLED\n\tjoypad = memnew(JoypadLinux(Input::get_singleton()));\n#endif\n',
     '#ifdef JOYDEV_ENABLED\n\tif (!JoypadMister::is_enabled()) { // MISTER: DDR joystick replaces JoypadLinux.\n'
     '\t\tjoypad = memnew(JoypadLinux(Input::get_singleton()));\n\t}\n#endif\n')
edit(OC, "if (joypad) {\n\t\t\tjoypad->process_joypads();",
     '#ifdef JOYDEV_ENABLED\n\t\tjoypad->process_joypads();\n#endif\n',
     '#ifdef JOYDEV_ENABLED\n\t\tif (joypad) {\n\t\t\tjoypad->process_joypads();\n\t\t}\n#endif\n')

# ---- Game-side hot path, engine fix (behaviour-neutral) ----
# The HUD re-applies the same colour override every physics tick
# (ui/hud/info.gd:44, ui/hud/p1.gd:34,58). Each call sends
# NOTIFICATION_THEME_CHANGED down the subtree (debug profile: 1.3 ms/tick for
# 3 calls). Re-setting an identical value changes nothing, so skip it.
CC = "scene/gui/control.cpp"
for kind, typ in (("color", "Color"), ("constant", "int"), ("font_size", "int")):
    arg = {"color": "p_color", "constant": "p_constant", "font_size": "p_font_size"}[kind]
    head = (f'void Control::add_theme_{kind}_override(const StringName &p_name, {"const Color &" if typ == "Color" else "int "}{arg}) {{\n'
            '\tERR_MAIN_THREAD_GUARD;\n')
    edit(CC, f"MISTER: unchanged {kind} override",
         head + f'\tdata.theme_{kind}_override[p_name] = {arg};\n',
         head + f'\tconst {typ} *mf_old = data.theme_{kind}_override.getptr(p_name);\n'
         f'\tif (mf_old && *mf_old == {arg}) {{\n\t\treturn; // MISTER: unchanged {kind} override, nothing to notify.\n\t}}\n'
         f'\tdata.theme_{kind}_override[p_name] = {arg};\n')

# ---- Vorbis: share parsed headers + decode codebooks per stream (PLAN §6.2 step 1) ----
# Every AudioStreamOggVorbis::instantiate_playback() re-parsed the three header
# packets into a fresh vorbis_info and rebuilt the codebooks in
# vorbis_synthesis_init: ~6 ms per SFX play on the A9. libvorbis builds
# ci->fullbooks once per vorbis_info and decoding only reads it, so the stream
# builds one at load and playbacks share it. MISTER_OGG_SHARED=0 = upstream.
VH = "modules/vorbis/audio_stream_ogg_vorbis.h"
VC = "modules/vorbis/audio_stream_ogg_vorbis.cpp"
edit(VH, "struct OggVorbisSharedSetup",
     '#include <vorbis/codec.h>\n',
     '#include <vorbis/codec.h>\n\n#include "core/templates/safe_refcount.h"\n\n'
     '// MISTER: parsed Vorbis headers + decode codebooks, built once per stream and\n'
     '// shared read-only by its playbacks (libvorbis builds the codebooks on the first\n'
     '// vorbis_synthesis_init of a vorbis_info; decoding only reads it).\n'
     'struct OggVorbisSharedSetup {\n'
     '\tvorbis_info info;\n'
     '\tSafeRefCount refs;\n'
     '\tstatic bool enabled();\n'
     '\tstatic OggVorbisSharedSetup *create(const Ref<OggPacketSequence> &p_sequence);\n'
     '\tOggVorbisSharedSetup *ref() {\n\t\trefs.ref();\n\t\treturn this;\n\t}\n'
     '\tvoid unref();\n'
     '};\n')
edit(VH, "OggVorbisSharedSetup *shared_setup = nullptr; // MISTER: playback",
     '\tvorbis_dsp_state dsp_state;\n\tvorbis_block block;\n',
     '\tvorbis_dsp_state dsp_state;\n\tvorbis_block block;\n'
     '\tOggVorbisSharedSetup *shared_setup = nullptr; // MISTER: playback holds a ref while alive.\n'
     '\tvorbis_info *vi = &info; // MISTER: own info, or the stream\'s shared one.\n')
edit(VH, "OggVorbisSharedSetup *shared_setup = nullptr; // MISTER: stream",
     '\tRef<OggPacketSequence> packet_sequence;\n',
     '\tRef<OggPacketSequence> packet_sequence;\n'
     '\tOggVorbisSharedSetup *shared_setup = nullptr; // MISTER: stream owns one ref.\n')

edit(VC, "OggVorbisSharedSetup::create",
     'bool AudioStreamPlaybackOggVorbis::_alloc_vorbis() {\n',
     'bool OggVorbisSharedSetup::enabled() {\n'
     '\tstatic int on = -1;\n'
     '\tif (on < 0) {\n\t\tconst char *e = getenv("MISTER_OGG_SHARED");\n\t\ton = (e != nullptr && e[0] == \'0\') ? 0 : 1;\n\t}\n'
     '\treturn on == 1;\n}\n\n'
     'OggVorbisSharedSetup *OggVorbisSharedSetup::create(const Ref<OggPacketSequence> &p_sequence) {\n'
     '\tOggVorbisSharedSetup *s = memnew(OggVorbisSharedSetup);\n'
     '\ts->refs.init();\n'
     '\tvorbis_info_init(&s->info);\n'
     '\tvorbis_comment comment;\n'
     '\tvorbis_comment_init(&comment);\n'
     '\tRef<OggPacketSequencePlayback> seq = p_sequence->instantiate_playback();\n'
     '\tbool ok = true;\n'
     '\tfor (int i = 0; i < 3 && ok; i++) {\n'
     '\t\togg_packet *packet;\n'
     '\t\tok = seq->next_ogg_packet(&packet) && vorbis_synthesis_headerin(&s->info, &comment, packet) == 0;\n'
     '\t}\n'
     '\tvorbis_comment_clear(&comment);\n'
     '\tif (ok) {\n'
     '\t\t// Build the codebooks now, on this thread, so playbacks never write the shared info.\n'
     '\t\tvorbis_dsp_state warm;\n'
     '\t\tok = vorbis_synthesis_init(&warm, &s->info) == 0;\n'
     '\t\tif (ok) {\n\t\t\tvorbis_dsp_clear(&warm);\n\t\t}\n'
     '\t}\n'
     '\tif (!ok) {\n\t\tvorbis_info_clear(&s->info);\n\t\tmemdelete(s);\n\t\treturn nullptr;\n\t}\n'
     '\treturn s;\n}\n\n'
     'void OggVorbisSharedSetup::unref() {\n'
     '\tif (refs.unref()) {\n\t\tvorbis_info_clear(&info);\n\t\tmemdelete(this);\n\t}\n}\n\n'
     'bool AudioStreamPlaybackOggVorbis::_alloc_vorbis() {\n')
edit(VC, "MISTER: shared setup, no header parse",
     '\tERR_FAIL_COND_V(vorbis_data.is_null(), false);\n\tvorbis_data_playback = vorbis_data->instantiate_playback();\n',
     '\tERR_FAIL_COND_V(vorbis_data.is_null(), false);\n\tvorbis_data_playback = vorbis_data->instantiate_playback();\n\n'
     '\tif (vorbis_stream.is_valid() && vorbis_stream->shared_setup != nullptr) {\n'
     '\t\t// MISTER: shared setup, no header parse or codebook build. seek() positions\n'
     '\t\t// the packet stream itself; header packets decode as OV_ENOTAUDIO there.\n'
     '\t\tshared_setup = vorbis_stream->shared_setup->ref();\n'
     '\t\tvi = &shared_setup->info;\n'
     '\t\tERR_FAIL_COND_V_MSG(vorbis_synthesis_init(&dsp_state, vi) != 0, false, "Error initializing dsp state");\n'
     '\t\tdsp_state_is_allocated = true;\n'
     '\t\tERR_FAIL_COND_V_MSG(vorbis_block_init(&dsp_state, &block) != 0, false, "Error initializing block");\n'
     '\t\tblock_is_allocated = true;\n'
     '\t\tready = true;\n'
     '\t\treturn true;\n'
     '\t}\n')
edit(VC, "vi->channels > 1",
     '\tif (info.channels > 1) {\n',
     '\tif (vi->channels > 1) {\n')
edit(VC, "shared_setup->unref(); // MISTER: after the dsp state",
     '\tif (info_is_allocated) {\n\t\tvorbis_info_clear(&info);\n\t}\n}\n',
     '\tif (info_is_allocated) {\n\t\tvorbis_info_clear(&info);\n\t}\n'
     '\tif (shared_setup != nullptr) {\n\t\tshared_setup->unref(); // MISTER: after the dsp state that used it.\n\t}\n}\n')
edit(VC, "MISTER: rebuild the shared setup",
     '\tpacket_sequence->set_sampling_rate(info.rate);\n',
     '\tpacket_sequence->set_sampling_rate(info.rate);\n\n'
     '\t// MISTER: rebuild the shared setup; running playbacks keep their own ref.\n'
     '\tif (shared_setup != nullptr) {\n\t\tshared_setup->unref();\n\t\tshared_setup = nullptr;\n\t}\n'
     '\tif (OggVorbisSharedSetup::enabled()) {\n\t\tshared_setup = OggVorbisSharedSetup::create(packet_sequence);\n\t}\n')
edit(VC, "MISTER: release the shared setup",
     'AudioStreamOggVorbis::~AudioStreamOggVorbis() {}\n',
     'AudioStreamOggVorbis::~AudioStreamOggVorbis() {\n'
     '\tif (shared_setup != nullptr) {\n\t\tshared_setup->unref(); // MISTER: release the shared setup.\n\t}\n}\n')
edit(VC, "#include <stdlib.h> // MISTER",
     '#include <ogg/ogg.h>\n',
     '#include <ogg/ogg.h>\n#include <stdlib.h> // MISTER: getenv\n')

# ---- Vorbis: PCM cache for short clips (PLAN §6.2 step 2) ----
# Short non-looping clips (all 45 SFX: 0.02-1.35 s, 20.8 s total) are decoded
# once at load, through the normal playback's mix() (so the same cubic
# resampler, to the mix rate), into a 16-bit stereo AudioStreamWAV. Plays then
# cost an AudioStreamPlaybackWAV allocation and no Vorbis decode on the audio
# thread. MISTER_OGG_PCM_MAX_S=<seconds> (default 3; 0 = off).
edit(VH, '#include "scene/resources/audio_stream_wav.h" // MISTER',
     '#include "servers/audio/audio_stream.h"\n',
     '#include "servers/audio/audio_stream.h"\n#include "scene/resources/audio_stream_wav.h" // MISTER: PCM cache\n')
edit(VH, "Ref<AudioStreamWAV> pcm_cache;",
     '\tOggVorbisSharedSetup *shared_setup = nullptr; // MISTER: stream owns one ref.\n',
     '\tOggVorbisSharedSetup *shared_setup = nullptr; // MISTER: stream owns one ref.\n'
     '\tRef<AudioStreamWAV> pcm_cache; // MISTER: short clips, decoded once.\n'
     '\tvoid _build_pcm_cache();\n')
edit(VC, "void AudioStreamOggVorbis::_build_pcm_cache()",
     'Ref<AudioStreamPlayback> AudioStreamOggVorbis::instantiate_playback() {\n',
     'void AudioStreamOggVorbis::_build_pcm_cache() {\n'
     '\tpcm_cache.unref();\n'
     '\tstatic double max_s = -1.0;\n'
     '\tif (max_s < 0.0) {\n\t\tconst char *e = getenv("MISTER_OGG_PCM_MAX_S");\n\t\tmax_s = e ? atof(e) : 3.0;\n\t}\n'
     '\tAudioServer *as = AudioServer::get_singleton();\n'
     '\tconst double len = get_length();\n'
     '\tif (max_s <= 0.0 || as == nullptr || len <= 0.0 || len > max_s) {\n\t\treturn;\n\t}\n'
     '\tRef<AudioStreamPlaybackOggVorbis> pb = instantiate_playback();\n'
     '\tif (pb.is_null()) {\n\t\treturn;\n\t}\n'
     '\tpb->looping_override = true; // Decode exactly once, whatever `loop` is set to later.\n'
     '\tpb->looping = false;\n'
     '\tpb->start(0.0);\n'
     '\tconst int rate = int(as->get_mix_rate());\n'
     '\tconst int max_frames = int(len * rate) + 8192;\n'
     '\tconst int chunk = 1024;\n'
     '\tVector<uint8_t> data;\n'
     '\tdata.resize((max_frames + chunk) * 4);\n'
     '\tint16_t *dst = (int16_t *)data.ptrw();\n'
     '\tAudioFrame buf[chunk];\n'
     '\tint total = 0;\n'
     '\twhile (total < max_frames) {\n'
     '\t\tint n = pb->mix(buf, 1.0, chunk);\n'
     '\t\tfor (int i = 0; i < n; i++) {\n'
     '\t\t\tdst[(total + i) * 2 + 0] = (int16_t)CLAMP(Math::fast_ftoi(buf[i].left * 32767.0f), -32768, 32767);\n'
     '\t\t\tdst[(total + i) * 2 + 1] = (int16_t)CLAMP(Math::fast_ftoi(buf[i].right * 32767.0f), -32768, 32767);\n'
     '\t\t}\n'
     '\t\ttotal += n;\n'
     '\t\tif (n < chunk) {\n\t\t\tbreak; // End of stream.\n\t\t}\n'
     '\t}\n'
     '\tdata.resize(total * 4);\n'
     '\tpcm_cache.instantiate();\n'
     '\tpcm_cache->set_format(AudioStreamWAV::FORMAT_16_BITS);\n'
     '\tpcm_cache->set_stereo(true);\n'
     '\tpcm_cache->set_mix_rate(rate);\n'
     '\tpcm_cache->set_loop_mode(AudioStreamWAV::LOOP_DISABLED);\n'
     '\tpcm_cache->set_data(data);\n'
     '}\n\n'
     'Ref<AudioStreamPlayback> AudioStreamOggVorbis::instantiate_playback() {\n'
     '\tif (pcm_cache.is_valid() && !loop) {\n'
     '\t\treturn pcm_cache->instantiate_playback(); // MISTER: decoded once at load.\n'
     '\t}\n')
edit(VC, "_build_pcm_cache(); // MISTER",
     '\tif (OggVorbisSharedSetup::enabled()) {\n\t\tshared_setup = OggVorbisSharedSetup::create(packet_sequence);\n\t}\n',
     '\tif (OggVorbisSharedSetup::enabled()) {\n\t\tshared_setup = OggVorbisSharedSetup::create(packet_sequence);\n\t}\n'
     '\t_build_pcm_cache(); // MISTER: after the shared setup, which makes the decode cheap.\n')

# ---- Per-tick setters that do full work for unchanged state (PLAN §6.5) ----
# AnimatedSprite2D::play() validated the name by building, sorting and
# linearly searching a Vector<String> of every animation name, and always
# emitted property_list_changed + queue_redraw, even when the same animation
# was already playing. The game calls it every tick (mega gold, bonus
# entrance, state machine). Same checks, hash lookup; return early when the
# call changes nothing.
AS = "scene/2d/animated_sprite_2d.cpp"
edit(AS, "!frames->has_animation(name), vformat(\"There is no animation",
     '\tERR_FAIL_COND_MSG(!frames->get_animation_names().has(name), vformat("There is no animation with name \'%s\'.", name));\n',
     '\tERR_FAIL_COND_MSG(!frames->has_animation(name), vformat("There is no animation with name \'%s\'.", name)); // MISTER: hash lookup.\n')
edit(AS, "MISTER: already playing this animation",
     '\tplaying = true;\n\tcustom_speed_scale = p_custom_scale;\n\n\tif (name != animation) {\n',
     '\t// MISTER: already playing this animation at this speed -> only the end-of-animation restart below can change state.\n'
     '\tconst bool mf_same = playing && name == animation && custom_speed_scale == p_custom_scale;\n'
     '\tconst int mf_frame = frame;\n\tconst float mf_progress = frame_progress;\n\n'
     '\tplaying = true;\n\tcustom_speed_scale = p_custom_scale;\n\n\tif (name != animation) {\n')
edit(AS, "mf_same && frame == mf_frame",
     '\tset_process_internal(true);\n\tnotify_property_list_changed();\n\tqueue_redraw();\n}\n',
     '\tif (mf_same && frame == mf_frame && frame_progress == mf_progress) {\n\t\treturn; // MISTER: nothing changed.\n\t}\n'
     '\tset_process_internal(true);\n\tnotify_property_list_changed();\n\tqueue_redraw();\n}\n')
# ShaderMaterial::set_shader_parameter forwarded every call to
# RS::material_set_param (material re-upload) even for an unchanged value.
edit("scene/resources/material.cpp", "MISTER: unchanged shader parameter",
     '\t\t} else {\n\t\t\t*v = p_value;\n\t\t}\n',
     '\t\t} else {\n\t\t\tif (*v == p_value && v->get_type() == p_value.get_type()) {\n'
     '\t\t\t\treturn; // MISTER: unchanged shader parameter, nothing to upload.\n\t\t\t}\n'
     '\t\t\t*v = p_value;\n\t\t}\n')

# ---- Thumb-2 builds (-mthumb): GCC 10.2.1 ICEs (cselib.c:2614) on this file in
# Thumb mode with NEON; compile just this file as ARM. No effect on -marm builds.
edit("scene/resources/surface_tool.cpp", "MISTER: GCC 10.2 ICE",
     '#include "surface_tool.h"\n',
     '#if defined(__arm__) && defined(__thumb__)\n#pragma GCC target("arm") // MISTER: GCC 10.2 ICE (cselib.c:2614) in Thumb-2 mode.\n#endif\n\n'
     '#include "surface_tool.h"\n')
# CollisionShape2D::set_disabled had no early return: every call queued a
# redraw and pushed area/body_set_shape_disabled to the physics server.
# diamond.gd and bonus_level_entrance.gd set it every tick.
edit("scene/2d/physics/collision_shape_2d.cpp", "MISTER: unchanged disabled",
     'void CollisionShape2D::set_disabled(bool p_disabled) {\n\tdisabled = p_disabled;\n',
     'void CollisionShape2D::set_disabled(bool p_disabled) {\n'
     '\tif (disabled == p_disabled && collision_object && collision_object->is_shape_owner_disabled(owner_id) == p_disabled) {\n'
     '\t\treturn; // MISTER: unchanged disabled state, nothing to push to the physics server.\n\t}\n'
     '\tdisabled = p_disabled;\n')

# ---- Canvas cull: early return for empty leaf items (PLAN §6.13) ----
# RendererCanvasCull::_cull_canvas_item was the top engine symbol in real play
# (8.8% of the main thread). Every Node2D is a canvas item, including ones that
# never draw (the 15 RayCast2D per enemy, every CollisionShape2D, marker
# nodes). For an item with no commands, no children and none of the special
# roles below, _attach_canvas_item_for_draw does nothing; the only persistent
# state the cull writes for it is repeat_size/repeat_times. Keep that write and
# skip the rect/transform/modulate work.
edit("servers/rendering/renderer_canvas_cull.cpp", "MISTER: empty leaf item",
     '\tif (!(ci->visibility_layer & p_canvas_cull_mask)) {\n\t\treturn;\n\t}\n\n\tif (ci->children_order_dirty) {\n',
     '\tif (!(ci->visibility_layer & p_canvas_cull_mask)) {\n\t\treturn;\n\t}\n\n'
     '\tif (ci->commands == nullptr && ci->child_items.is_empty() && !ci->visibility_notifier && !ci->vp_render &&\n'
     '\t\t\t!ci->copy_back_buffer && !ci->canvas_group && !ci->sort_y && !ci->clip) {\n'
     '\t\t// MISTER: empty leaf item, nothing to draw or notify.\n'
     '\t\tif (!ci->repeat_source) {\n\t\t\tci->repeat_size = p_repeat_size;\n\t\t\tci->repeat_times = p_repeat_times;\n\t\t}\n'
     '\t\treturn;\n\t}\n\n'
     '\tif (ci->children_order_dirty) {\n')

# ---- Process-list re-sort: near-sorted fast path (PLAN §6.13) ----
# Any node that starts (physics) processing is appended to its process group
# and the group is marked dirty; the next frame fully re-sorted the whole list
# (hundreds of nodes) with a comparator that walks both nodes' ancestor chains
# (Node::is_greater_than: 2.85% of the main thread in real play: on-screen
# enablers, pools and AnimatedSprite2D pause/play toggle processing every
# frame). The list is sorted except for the appended tail, so: find the sorted
# prefix, sort the short tail, binary-insert it. The comparator is a strict
# total order (priority, then tree order), so the result equals the full sort;
# any other disorder (e.g. move_child) falls back to the full sort.
ST = "scene/main/scene_tree.cpp"
edit(ST, "_mister_sort_process_list",
     'void SceneTree::_process_group(ProcessGroup *p_group, bool p_physics) {\n',
     '// MISTER: near-sorted fast path for the process lists (see _process_group).\n'
     'template <typename C>\n'
     'static void _mister_sort_process_list(Vector<Node *> &r_nodes) {\n'
     '\tconst int n = r_nodes.size();\n'
     '\tif (n < 2) {\n\t\treturn;\n\t}\n'
     '\tC comp;\n'
     '\tNode **p = r_nodes.ptrw();\n'
     '\tint k = 1;\n'
     '\twhile (k < n && !comp(p[k], p[k - 1])) {\n\t\tk++;\n\t}\n'
     '\tif (k >= n) {\n\t\treturn;\n\t}\n'
     '\tconst int tail = n - k;\n'
     '\tif (tail > 16 && tail > n / 8) {\n\t\tr_nodes.sort_custom<C>();\n\t\treturn;\n\t}\n'
     '\tSortArray<Node *, C> sorter;\n'
     '\tsorter.sort(p + k, tail);\n'
     '\tfor (int i = k; i < n; i++) {\n'
     '\t\tNode *x = p[i];\n'
     '\t\tint lo = 0, hi = i;\n'
     '\t\twhile (lo < hi) {\n\t\t\tconst int mid = (lo + hi) / 2;\n'
     '\t\t\tif (comp(x, p[mid])) {\n\t\t\t\thi = mid;\n\t\t\t} else {\n\t\t\t\tlo = mid + 1;\n\t\t\t}\n\t\t}\n'
     '\t\tif (lo < i) {\n\t\t\tmemmove(p + lo + 1, p + lo, (i - lo) * sizeof(Node *));\n\t\t\tp[lo] = x;\n\t\t}\n'
     '\t}\n'
     '}\n\n'
     'void SceneTree::_process_group(ProcessGroup *p_group, bool p_physics) {\n')
edit(ST, "_mister_sort_process_list<Node::ComparatorWithPhysicsPriority>",
     '\t\t\tnodes.sort_custom<Node::ComparatorWithPhysicsPriority>();\n',
     '\t\t\t_mister_sort_process_list<Node::ComparatorWithPhysicsPriority>(nodes); // MISTER\n')
edit(ST, "_mister_sort_process_list<Node::ComparatorWithPriority>",
     '\t\t\tnodes.sort_custom<Node::ComparatorWithPriority>();\n',
     '\t\t\t_mister_sort_process_list<Node::ComparatorWithPriority>(nodes); // MISTER\n')

# ---- BVH segment cull: exact pre-tests before the slab test (PLAN §6.13) ----
# BVH_Tree::_cull_segment_iterative was 4.5% of the main thread in real play
# (~80 short detector rays per tick). Every visited node converted its box and
# ran Rect2::intersects_segment: up to 4 divides + ~10 branches, to answer a
# yes/no question. Pre-test with the per-axis range rejects that function
# starts each axis with (same float expressions, so identical results), and
# accept outright a segment that moves along at most one axis (axis-aligned
# rays), where the slab test can only return true after passing them.
edit("core/math/bvh_abb.h", "MISTER: exact pre-tests",
     '\tbool intersects_segment(const Segment &p_s) const {\n\t\tBOUNDS bb;\n\t\tto(bb);\n\t\treturn bb.intersects_segment(p_s.from, p_s.to);\n\t}\n',
     '\tbool intersects_segment(const Segment &p_s) const {\n'
     '\t\t// MISTER: exact pre-tests before the general slab test (divide-free).\n'
     '\t\tint moving_axes = 0;\n'
     '\t\tfor (int axis = 0; axis < POINT::AXIS_COUNT; ++axis) {\n'
     '\t\t\tconst real_t a = p_s.from[axis];\n'
     '\t\t\tconst real_t b = p_s.to[axis];\n'
     '\t\t\tconst real_t box_begin = min[axis];\n'
     '\t\t\tconst real_t box_end = box_begin + (-neg_max[axis] - box_begin); // as to() + BOUNDS: position + size\n'
     '\t\t\tconst real_t lo = a < b ? a : b;\n'
     '\t\t\tconst real_t hi = a < b ? b : a;\n'
     '\t\t\tif (lo > box_end || hi < box_begin) {\n\t\t\t\treturn false;\n\t\t\t}\n'
     '\t\t\tmoving_axes += (a != b) ? 1 : 0;\n'
     '\t\t}\n'
     '\t\tif (moving_axes <= 1) {\n\t\t\treturn true;\n\t\t}\n'
     '\t\tBOUNDS bb;\n\t\tto(bb);\n\t\treturn bb.intersects_segment(p_s.from, p_s.to);\n\t}\n')

# ---- Canvas z-lists: touch only the z range actually used (PLAN §6.14) ----
# _render_canvas_item_tree memset two 8192-entry pointer arrays (64 KB) and
# scanned all 8192 z slots to link the non-empty ones, once per canvas layer
# per viewport per frame (the scan loop alone: ~2% of the main thread; memset
# 0.8%). The game uses a handful of z values. Track the lowest/highest slot
# written (the only writer is _attach_canvas_item_for_draw), scan that range,
# and keep the arrays all-null between calls by clearing just that range once
# the draw list is linked (the list chains through Item::next).
RCC = "servers/rendering/renderer_canvas_cull.cpp"
RCH = "servers/rendering/renderer_canvas_cull.h"
edit(RCH, "z_used_min",
     '\tRendererCanvasRender::Item **z_list;\n\tRendererCanvasRender::Item **z_last_list;\n',
     '\tRendererCanvasRender::Item **z_list;\n\tRendererCanvasRender::Item **z_last_list;\n'
     '\tint z_used_min = z_range; // MISTER: z slots written this tree render\n\tint z_used_max = -1;\n')
edit(RCC, "MISTER: arrays start all-null",
     '\tz_list = (RendererCanvasRender::Item **)memalloc(z_range * sizeof(RendererCanvasRender::Item *));\n'
     '\tz_last_list = (RendererCanvasRender::Item **)memalloc(z_range * sizeof(RendererCanvasRender::Item *));\n',
     '\tz_list = (RendererCanvasRender::Item **)memalloc(z_range * sizeof(RendererCanvasRender::Item *));\n'
     '\tz_last_list = (RendererCanvasRender::Item **)memalloc(z_range * sizeof(RendererCanvasRender::Item *));\n'
     '\t// MISTER: arrays start all-null and are kept so between tree renders.\n'
     '\tmemset(z_list, 0, z_range * sizeof(RendererCanvasRender::Item *));\n'
     '\tmemset(z_last_list, 0, z_range * sizeof(RendererCanvasRender::Item *));\n')
edit(RCC, "MISTER: record the z slot",
     '\t\t\t} else {\n\t\t\t\tr_z_list[zidx] = ci;\n\t\t\t\tr_z_last_list[zidx] = ci;\n\t\t\t}\n',
     '\t\t\t} else {\n\t\t\t\tr_z_list[zidx] = ci;\n\t\t\t\tr_z_last_list[zidx] = ci;\n'
     '\t\t\t\t// MISTER: record the z slot for the ranged link/clear in _render_canvas_item_tree.\n'
     '\t\t\t\tz_used_min = MIN(z_used_min, zidx);\n\t\t\t\tz_used_max = MAX(z_used_max, zidx);\n'
     '\t\t\t}\n')
edit(RCC, "MISTER: ranged z link",
     '\tmemset(z_list, 0, z_range * sizeof(RendererCanvasRender::Item *));\n'
     '\tmemset(z_last_list, 0, z_range * sizeof(RendererCanvasRender::Item *));\n\n'
     '\tfor (int i = 0; i < p_child_item_count; i++) {\n',
     '\t// MISTER: ranged z link — z_list/z_last_list are all-null here (cleared below after each use).\n'
     '\tz_used_min = z_range;\n\tz_used_max = -1;\n\n'
     '\tfor (int i = 0; i < p_child_item_count; i++) {\n')
edit(RCC, "MISTER: clear only the used range",
     '\tfor (int i = 0; i < z_range; i++) {\n\t\tif (!z_list[i]) {\n\t\t\tcontinue;\n\t\t}\n'
     '\t\tif (!list) {\n\t\t\tlist = z_list[i];\n\t\t\tlist_end = z_last_list[i];\n\t\t} else {\n'
     '\t\t\tlist_end->next = z_list[i];\n\t\t\tlist_end = z_last_list[i];\n\t\t}\n\t}\n',
     '\tfor (int i = z_used_min; i <= z_used_max; i++) {\n\t\tif (!z_list[i]) {\n\t\t\tcontinue;\n\t\t}\n'
     '\t\tif (!list) {\n\t\t\tlist = z_list[i];\n\t\t\tlist_end = z_last_list[i];\n\t\t} else {\n'
     '\t\t\tlist_end->next = z_list[i];\n\t\t\tlist_end = z_last_list[i];\n\t\t}\n\t}\n'
     '\tif (z_used_max >= z_used_min) { // MISTER: clear only the used range; the list chains through Item::next.\n'
     '\t\tconst int n = z_used_max - z_used_min + 1;\n'
     '\t\tmemset(z_list + z_used_min, 0, n * sizeof(RendererCanvasRender::Item *));\n'
     '\t\tmemset(z_last_list + z_used_min, 0, n * sizeof(RendererCanvasRender::Item *));\n\t}\n')

# ---- GDScript: inline cache for GET_NAMED / SET_NAMED on objects (PLAN §6.16) ----
# Logic in src/godot/modules/gdscript/gdscript_mister_named_cache.cpp (copied
# above; the module compiles *.cpp). By-name property access on objects was
# ~18.8% (dispatch) of the main thread; see that file's header for the rules.
GFH = "modules/gdscript/gdscript_function.h"
GFC = "modules/gdscript/gdscript_function.cpp"
GVM = "modules/gdscript/gdscript_vm.cpp"
edit(GFH, "struct MisterNamedCache",
     '\tint _code_size = 0;\n\tint _default_arg_count = 0;\n',
     '\tint _code_size = 0;\n\tint _default_arg_count = 0;\n\n'
     '\t// MISTER: per-instruction inline cache for GET/SET_NAMED on objects\n'
     '\t// (gdscript_mister_named_cache.cpp). Allocated on first use, main thread only.\n'
     '\tstruct MisterNamedCache {\n'
     '\t\tenum Kind : uint8_t {\n\t\t\tEMPTY,\n\t\t\tUNCACHEABLE,\n\t\t\tMEMBER,\n\t\t\tNATIVE,\n\t\t};\n'
     '\t\tconst StringName *cls = nullptr; // key: object class (get_class_name() address)\n'
     '\t\tconst void *script = nullptr; // key: GDScript of the instance, or null\n'
     '\t\tRef<Script> script_ref; // keeps that script alive: its address cannot be reused\n'
     '\t\tMethodBind *method = nullptr; // NATIVE: property getter/setter\n'
     '\t\tconst void *member = nullptr; // MEMBER: const GDScript::MemberInfo *\n'
     '\t\tKind kind = EMPTY;\n'
     '\t\tuint8_t misses = 0; // key changes at this site; >4 -> slow path for good (megamorphic)\n'
     '\t};\n'
     '\tmutable MisterNamedCache *mister_named_cache = nullptr;\n'
     '\tMisterNamedCache &_mister_slot(int p_ip) const;\n'
     '\tvoid _mister_fill(MisterNamedCache &e, Object *p_obj, GDScriptInstance *p_gdi, const StringName &p_name, bool p_set) const;\n'
     '\tbool _mister_named_get(int p_ip, const Variant *p_src, const StringName &p_name, Variant *r_dst) const;\n'
     '\tbool _mister_named_set(int p_ip, Variant *p_dst, const StringName &p_name, const Variant *p_value) const;\n')
edit(GFC, "memdelete_arr(mister_named_cache)",
     'GDScriptFunction::~GDScriptFunction() {\n',
     'GDScriptFunction::~GDScriptFunction() {\n'
     '\tif (mister_named_cache) {\n\t\tmemdelete_arr(mister_named_cache); // MISTER\n\t\tmister_named_cache = nullptr;\n\t}\n')
edit(GVM, "_mister_named_set(ip,",
     '\t\t\t\tconst StringName *index = &_global_names_ptr[indexname];\n\n\t\t\t\tbool valid;\n\t\t\t\tdst->set_named(*index, *value, valid);\n',
     '\t\t\t\tconst StringName *index = &_global_names_ptr[indexname];\n\n'
     '\t\t\t\tif (dst->get_type() == Variant::OBJECT && _mister_named_set(ip, dst, *index, value)) { // MISTER: inline cache\n'
     '\t\t\t\t\tip += 4;\n\t\t\t\t\tDISPATCH_OPCODE;\n\t\t\t\t}\n\n'
     '\t\t\t\tbool valid;\n\t\t\t\tdst->set_named(*index, *value, valid);\n')
edit(GVM, "_mister_named_get(ip,",
     '\t\t\t\tconst StringName *index = &_global_names_ptr[indexname];\n\n\t\t\t\tbool valid;\n#ifdef DEBUG_ENABLED\n\t\t\t\t//allow better error message in cases where src and dst are the same stack position\n',
     '\t\t\t\tconst StringName *index = &_global_names_ptr[indexname];\n\n'
     '\t\t\t\tif (src->get_type() == Variant::OBJECT && _mister_named_get(ip, src, *index, dst)) { // MISTER: inline cache\n'
     '\t\t\t\t\tip += 4;\n\t\t\t\t\tDISPATCH_OPCODE;\n\t\t\t\t}\n\n'
     '\t\t\t\tbool valid;\n#ifdef DEBUG_ENABLED\n\t\t\t\t//allow better error message in cases where src and dst are the same stack position\n')

# ---- TYPE_POLYGON on the fabric (PLAN §6.19): StyleBoxFlat fills (HUD combo and bonus-time bars) ----
edit(RC, "MisterFabricBridge::polygon_created",
     '\tPolygonID id = polygon_buffers.last_id++;\n\n\tpolygon_buffers.polygons[id] = pb;\n\n\treturn id;\n}\n',
     '\tPolygonID id = polygon_buffers.last_id++;\n\n\tpolygon_buffers.polygons[id] = pb;\n\n'
     '\tMisterFabricBridge::polygon_created(id, p_indices, p_points, p_colors, p_uvs); // MISTER: GL keeps no CPU copy\n\n'
     '\treturn id;\n}\n')
edit(RC, "MisterFabricBridge::polygon_freed",
     'void RasterizerCanvasGLES3::free_polygon(PolygonID p_polygon) {\n',
     'void RasterizerCanvasGLES3::free_polygon(PolygonID p_polygon) {\n'
     '\tMisterFabricBridge::polygon_freed(p_polygon); // MISTER\n')
edit(RC, "MisterFabricBridge::emit_polygon",
     '\t\t\t\t\tstate.instance_data_array[r_index].ninepatch_margins[j] = 0;\n\t\t\t\t}\n\n\t\t\t\t_add_to_batch(r_index, r_batch_broken);\n\t\t\t} break;\n\n\t\t\tcase Item::Command::TYPE_PRIMITIVE: {\n',
     '\t\t\t\t\tstate.instance_data_array[r_index].ninepatch_margins[j] = 0;\n\t\t\t\t}\n\n'
     '\t\t\t\tif (MisterFabricBridge::active) {\n'
     '\t\t\t\t\tconst InstanceData &mfi = state.instance_data_array[r_index];\n'
     '\t\t\t\t\tconst Batch &mfb = state.canvas_instance_batches[state.current_batch_index];\n'
     '\t\t\t\t\tMisterFabricBridge::emit_polygon(mfi.world, polygon->polygon.polygon_id, mfi.modulation, polygon->texture, int(blend_mode), mfb.material);\n'
     '\t\t\t\t}\n\n'
     '\t\t\t\t_add_to_batch(r_index, r_batch_broken);\n\t\t\t} break;\n\n\t\t\tcase Item::Command::TYPE_PRIMITIVE: {\n')
edit(RC, "c->type != Item::Command::TYPE_POLYGON && // MISTER",
     '\t\t\t\tc->type != Item::Command::TYPE_CLIP_IGNORE && c->type != Item::Command::TYPE_ANIMATION_SLICE) {\n\t\t\tMisterFabricBridge::note_unhandled(int(c->type));\n',
     '\t\t\t\tc->type != Item::Command::TYPE_CLIP_IGNORE && c->type != Item::Command::TYPE_ANIMATION_SLICE &&\n'
     '\t\t\t\tc->type != Item::Command::TYPE_POLYGON && // MISTER: drawn by emit_polygon\n'
     '\t\t\t\ttrue) {\n\t\t\tMisterFabricBridge::note_unhandled(int(c->type));\n')

# ---- MISTER_FRAMELOG: per-frame timing log (measurement only; off unless the env is set) ----
MM = "main/main.cpp"
edit(MM, '#include "main/mister_framelog.h"',
     '#include "main.h"\n',
     '#include "main.h"\n#include "main/mister_framelog.h"\n')
edit(MM, "MisterFramelog::begin()",
     '\tconst uint64_t ticks = OS::get_singleton()->get_ticks_usec();\n\tEngine::get_singleton()->_frame_ticks = ticks;\n',
     '\tMisterFramelog::begin();\n'
     '\tconst uint64_t ticks = OS::get_singleton()->get_ticks_usec();\n\tEngine::get_singleton()->_frame_ticks = ticks;\n')
edit(MM, "MisterFramelog::mark_physics",
     '\tif (Input::get_singleton()->is_agile_input_event_flushing()) {\n\t\tInput::get_singleton()->flush_buffered_events();\n\t}\n\n\tuint64_t process_begin',
     '\tMisterFramelog::mark_physics(advance.physics_steps);\n'
     '\tif (Input::get_singleton()->is_agile_input_event_flushing()) {\n\t\tInput::get_singleton()->flush_buffered_events();\n\t}\n\n\tuint64_t process_begin')
edit(MM, "MisterFramelog::mark_process",
     '\tmessage_queue->flush();\n\n\tRenderingServer::get_singleton()->sync(); //sync if still drawing from previous frames.\n',
     '\tmessage_queue->flush();\n\tMisterFramelog::mark_process();\n\n\tRenderingServer::get_singleton()->sync(); //sync if still drawing from previous frames.\n')
edit(MM, "MisterFramelog::mark_draw",
     '\tprocess_ticks = OS::get_singleton()->get_ticks_usec() - process_begin;\n',
     '\tMisterFramelog::mark_draw();\n\tprocess_ticks = OS::get_singleton()->get_ticks_usec() - process_begin;\n')
edit(MM, "MisterFramelog::mark_tail",
     '\tOS::get_singleton()->add_frame_delay(DisplayServer::get_singleton()->window_can_draw());\n',
     '\tMisterFramelog::mark_tail();\n'
     '\tOS::get_singleton()->add_frame_delay(DisplayServer::get_singleton()->window_can_draw());\n'
     '\tif (MisterFramelog::enabled) {\n'
     '\t\tSceneTree *mf_tree = Object::cast_to<SceneTree>(OS::get_singleton()->get_main_loop());\n'
     '\t\tMisterFramelog::end(mf_tree ? mf_tree->get_node_count() : 0);\n'
     '\t}\n')
