/**************************************************************************/
/*  mister_null_gl.cpp                                                    */
/**************************************************************************/
/* See mister_null_gl.h.                                                     */
/**************************************************************************/

#include "mister_null_gl.h"

#include "platform_gl.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace MisterNullGL {

// What Mesa llvmpipe answered on the device (MISTER_BOOTLOG "gl" lines).
static const char *VERSION = "OpenGL ES 3.2 Mesa 21.3.9";
static const char *RENDERER = "llvmpipe (LLVM 11.0.0, 128 bits) (MiSTer null GL)";
static const char *VENDOR = "Mesa/X.org";
static const char *GLSL_VERSION = "OpenGL ES GLSL ES 3.20";
static const char *const EXTENSIONS[] = {
	"GL_ANDROID_extension_pack_es31a",
	"GL_ANGLE_pack_reverse_row_order",
	"GL_ANGLE_texture_compression_dxt3",
	"GL_ANGLE_texture_compression_dxt5",
	"GL_APPLE_texture_max_level",
	"GL_EXT_EGL_image_storage",
	"GL_EXT_base_instance",
	"GL_EXT_blend_func_extended",
	"GL_EXT_blend_minmax",
	"GL_EXT_buffer_storage",
	"GL_EXT_clear_texture",
	"GL_EXT_clip_control",
	"GL_EXT_clip_cull_distance",
	"GL_EXT_color_buffer_float",
	"GL_EXT_color_buffer_half_float",
	"GL_EXT_compressed_ETC1_RGB8_sub_texture",
	"GL_EXT_copy_image",
	"GL_EXT_depth_clamp",
	"GL_EXT_discard_framebuffer",
	"GL_EXT_disjoint_timer_query",
	"GL_EXT_draw_buffers",
	"GL_EXT_draw_buffers_indexed",
	"GL_EXT_draw_elements_base_vertex",
	"GL_EXT_draw_instanced",
	"GL_EXT_float_blend",
	"GL_EXT_frag_depth",
	"GL_EXT_geometry_point_size",
	"GL_EXT_geometry_shader",
	"GL_EXT_gpu_shader5",
	"GL_EXT_map_buffer_range",
	"GL_EXT_memory_object",
	"GL_EXT_memory_object_fd",
	"GL_EXT_multi_draw_arrays",
	"GL_EXT_occlusion_query_boolean",
	"GL_EXT_polygon_offset_clamp",
	"GL_EXT_primitive_bounding_box",
	"GL_EXT_read_format_bgra",
	"GL_EXT_render_snorm",
	"GL_EXT_robustness",
	"GL_EXT_sRGB_write_control",
	"GL_EXT_separate_shader_objects",
	"GL_EXT_shader_framebuffer_fetch_non_coherent",
	"GL_EXT_shader_group_vote",
	"GL_EXT_shader_implicit_conversions",
	"GL_EXT_shader_integer_mix",
	"GL_EXT_shader_io_blocks",
	"GL_EXT_tessellation_point_size",
	"GL_EXT_tessellation_shader",
	"GL_EXT_texture_border_clamp",
	"GL_EXT_texture_buffer",
	"GL_EXT_texture_compression_bptc",
	"GL_EXT_texture_compression_dxt1",
	"GL_EXT_texture_compression_rgtc",
	"GL_EXT_texture_compression_s3tc",
	"GL_EXT_texture_compression_s3tc_srgb",
	"GL_EXT_texture_cube_map_array",
	"GL_EXT_texture_filter_anisotropic",
	"GL_EXT_texture_filter_minmax",
	"GL_EXT_texture_format_BGRA8888",
	"GL_EXT_texture_mirror_clamp_to_edge",
	"GL_EXT_texture_norm16",
	"GL_EXT_texture_query_lod",
	"GL_EXT_texture_rg",
	"GL_EXT_texture_sRGB_R8",
	"GL_EXT_texture_sRGB_RG8",
	"GL_EXT_texture_sRGB_decode",
	"GL_EXT_texture_shadow_lod",
	"GL_EXT_texture_type_2_10_10_10_REV",
	"GL_EXT_texture_view",
	"GL_EXT_unpack_subimage",
	"GL_KHR_blend_equation_advanced",
	"GL_KHR_context_flush_control",
	"GL_KHR_debug",
	"GL_KHR_no_error",
	"GL_KHR_parallel_shader_compile",
	"GL_KHR_robust_buffer_access_behavior",
	"GL_KHR_robustness",
	"GL_KHR_texture_compression_astc_ldr",
	"GL_KHR_texture_compression_astc_sliced_3d",
	"GL_MESA_bgra",
	"GL_MESA_framebuffer_flip_y",
	"GL_MESA_shader_integer_functions",
	"GL_NV_conditional_render",
	"GL_NV_draw_buffers",
	"GL_NV_fbo_color_attachments",
	"GL_NV_image_formats",
	"GL_NV_pixel_buffer_object",
	"GL_NV_read_buffer",
	"GL_NV_read_depth",
	"GL_NV_read_depth_stencil",
	"GL_NV_read_stencil",
	"GL_OES_EGL_image",
	"GL_OES_EGL_image_external",
	"GL_OES_EGL_image_external_essl3",
	"GL_OES_EGL_sync",
	"GL_OES_compressed_ETC1_RGB8_texture",
	"GL_OES_copy_image",
	"GL_OES_depth24",
	"GL_OES_depth_texture",
	"GL_OES_depth_texture_cube_map",
	"GL_OES_draw_buffers_indexed",
	"GL_OES_draw_elements_base_vertex",
	"GL_OES_element_index_uint",
	"GL_OES_fbo_render_mipmap",
	"GL_OES_geometry_point_size",
	"GL_OES_geometry_shader",
	"GL_OES_get_program_binary",
	"GL_OES_gpu_shader5",
	"GL_OES_mapbuffer",
	"GL_OES_packed_depth_stencil",
	"GL_OES_primitive_bounding_box",
	"GL_OES_required_internalformat",
	"GL_OES_rgb8_rgba8",
	"GL_OES_sample_shading",
	"GL_OES_sample_variables",
	"GL_OES_shader_image_atomic",
	"GL_OES_shader_io_blocks",
	"GL_OES_shader_multisample_interpolation",
	"GL_OES_standard_derivatives",
	"GL_OES_stencil8",
	"GL_OES_surfaceless_context",
	"GL_OES_tessellation_point_size",
	"GL_OES_tessellation_shader",
	"GL_OES_texture_3D",
	"GL_OES_texture_border_clamp",
	"GL_OES_texture_buffer",
	"GL_OES_texture_cube_map_array",
	"GL_OES_texture_float",
	"GL_OES_texture_float_linear",
	"GL_OES_texture_half_float",
	"GL_OES_texture_half_float_linear",
	"GL_OES_texture_npot",
	"GL_OES_texture_stencil8",
	"GL_OES_texture_storage_multisample_2d_array",
	"GL_OES_texture_view",
	"GL_OES_vertex_array_object",
	"GL_OES_vertex_half_float",
	"GL_OES_viewport_array",
};
static const int NUM_EXTENSIONS = sizeof(EXTENSIONS) / sizeof(EXTENSIONS[0]);

static uint32_t next_name = 1; // Unique across every object type (the bridge keys textures by name).
static void *scratch = nullptr; // glMapBufferRange memory.
static size_t scratch_size = 0;

static void fill_names(GLsizei n, GLuint *r_names) {
	for (GLsizei i = 0; i < n; i++) {
		r_names[i] = next_name++;
	}
}

// Every entry point without a specific implementation: no effect, returns 0.
// Arguments are ignored; under the ARM EAPI the caller owns the stack, so any
// signature may call it (as gmloader's gl_missing_stub).
static uintptr_t gl_zero() {
	return 0;
}

static const GLubyte *get_string(GLenum p_name) {
	switch (p_name) {
		case GL_VERSION:
			return (const GLubyte *)VERSION;
		case GL_RENDERER:
			return (const GLubyte *)RENDERER;
		case GL_VENDOR:
			return (const GLubyte *)VENDOR;
		case GL_SHADING_LANGUAGE_VERSION:
			return (const GLubyte *)GLSL_VERSION;
		default:
			return (const GLubyte *)"";
	}
}

static const GLubyte *get_stringi(GLenum p_name, GLuint p_index) {
	if (p_name == GL_EXTENSIONS && p_index < (GLuint)NUM_EXTENSIONS) {
		return (const GLubyte *)EXTENSIONS[p_index];
	}
	return nullptr;
}

static int64_t integer_value(GLenum p_pname, int p_index) {
	switch (p_pname) {
		case GL_NUM_EXTENSIONS:
			return NUM_EXTENSIONS;
		case GL_MAJOR_VERSION:
			return 3;
		case GL_MINOR_VERSION:
			return 2;
		case GL_MAX_TEXTURE_SIZE:
		case GL_MAX_RENDERBUFFER_SIZE:
		case GL_MAX_VIEWPORT_DIMS:
			return 16384;
		case GL_MAX_TEXTURE_IMAGE_UNITS:
		case GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS:
			return 32;
		case GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS:
			return 96;
		case GL_MAX_UNIFORM_BLOCK_SIZE:
			return 65536;
		case GL_MAX_SAMPLES:
			return 4;
		case GL_MAX_VERTEX_ATTRIBS:
			return 16;
		case GL_MAX_ARRAY_TEXTURE_LAYERS:
		case GL_MAX_3D_TEXTURE_SIZE:
			return 2048;
		case GL_MAX_CUBE_MAP_TEXTURE_SIZE:
			return 16384;
		case GL_MAX_UNIFORM_BUFFER_BINDINGS:
		case GL_MAX_VERTEX_UNIFORM_BLOCKS:
		case GL_MAX_FRAGMENT_UNIFORM_BLOCKS:
			return 16;
		case GL_MAX_DRAW_BUFFERS:
		case GL_MAX_COLOR_ATTACHMENTS:
			return 8;
		case GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT:
			return 16;
		default:
			(void)p_index;
			return 0;
	}
}

static int values_for(GLenum p_pname) {
	return p_pname == GL_MAX_VIEWPORT_DIMS ? 2 : 1;
}

static void get_integerv(GLenum p_pname, GLint *r_data) {
	for (int i = 0; i < values_for(p_pname); i++) {
		r_data[i] = (GLint)integer_value(p_pname, i);
	}
}

static void get_integer64v(GLenum p_pname, GLint64 *r_data) {
	for (int i = 0; i < values_for(p_pname); i++) {
		r_data[i] = integer_value(p_pname, i);
	}
}

static void get_floatv(GLenum p_pname, GLfloat *r_data) {
	r_data[0] = p_pname == 0x84FF ? 16.0f : (GLfloat)integer_value(p_pname, 0); // 0x84FF: MAX_TEXTURE_MAX_ANISOTROPY_EXT
}

static void get_booleanv(GLenum p_pname, GLboolean *r_data) {
	r_data[0] = integer_value(p_pname, 0) != 0;
}

static void gen_names(GLsizei p_n, GLuint *r_names) {
	fill_names(p_n, r_names);
}

static GLuint create_object() {
	return next_name++;
}

static GLuint create_shader(GLenum) {
	return next_name++;
}

static void get_objectiv(GLuint, GLenum p_pname, GLint *r_params) {
	// COMPILE_STATUS / LINK_STATUS / VALIDATE_STATUS succeed; lengths and counts are 0.
	r_params[0] = (p_pname == GL_COMPILE_STATUS || p_pname == GL_LINK_STATUS || p_pname == GL_VALIDATE_STATUS) ? GL_TRUE : 0;
}

static void get_info_log(GLuint, GLsizei p_buf_size, GLsizei *r_length, GLchar *r_log) {
	if (r_length) {
		*r_length = 0;
	}
	if (r_log && p_buf_size > 0) {
		r_log[0] = 0;
	}
}

static void get_program_binary(GLuint, GLsizei, GLsizei *r_length, GLenum *r_format, void *) {
	if (r_length) {
		*r_length = 0;
	}
	if (r_format) {
		*r_format = 0;
	}
}

static GLint get_location(GLuint, const GLchar *) {
	return 0;
}

static GLuint get_block_index(GLuint, const GLchar *) {
	return 0;
}

static GLenum check_framebuffer_status(GLenum) {
	return GL_FRAMEBUFFER_COMPLETE;
}

static void *map_buffer_range(GLenum, GLintptr, GLsizeiptr p_length, GLbitfield) {
	if ((size_t)p_length > scratch_size) {
		free(scratch);
		scratch_size = (size_t)p_length;
		scratch = malloc(scratch_size);
	}
	return scratch;
}

static GLboolean unmap_buffer(GLenum) {
	return GL_TRUE;
}

static GLsync fence_sync(GLenum, GLbitfield) {
	return (GLsync)(uintptr_t)(next_name++);
}

static GLenum client_wait_sync(GLsync, GLbitfield, GLuint64) {
	return GL_ALREADY_SIGNALED;
}

static void get_synciv(GLsync, GLenum, GLsizei p_count, GLsizei *r_length, GLint *r_values) {
	if (p_count > 0 && r_values) {
		r_values[0] = GL_SIGNALED;
	}
	if (r_length) {
		*r_length = 1;
	}
}

static void get_query_ui64v(GLuint, GLenum, GLuint64 *r_params) {
	r_params[0] = 0;
}

static void get_query_uiv(GLuint, GLenum, GLuint *r_params) {
	r_params[0] = 0;
}

struct Entry {
	const char *name;
	void *fn;
};

static const Entry ENTRIES[] = {
	{ "glGetString", (void *)&get_string },
	{ "glGetStringi", (void *)&get_stringi },
	{ "glGetIntegerv", (void *)&get_integerv },
	{ "glGetInteger64v", (void *)&get_integer64v },
	{ "glGetFloatv", (void *)&get_floatv },
	{ "glGetBooleanv", (void *)&get_booleanv },
	{ "glGenBuffers", (void *)&gen_names },
	{ "glGenTextures", (void *)&gen_names },
	{ "glGenFramebuffers", (void *)&gen_names },
	{ "glGenRenderbuffers", (void *)&gen_names },
	{ "glGenVertexArrays", (void *)&gen_names },
	{ "glGenQueries", (void *)&gen_names },
	{ "glGenSamplers", (void *)&gen_names },
	{ "glGenTransformFeedbacks", (void *)&gen_names },
	{ "glCreateProgram", (void *)&create_object },
	{ "glCreateShader", (void *)&create_shader },
	{ "glGetShaderiv", (void *)&get_objectiv },
	{ "glGetProgramiv", (void *)&get_objectiv },
	{ "glGetShaderInfoLog", (void *)&get_info_log },
	{ "glGetProgramInfoLog", (void *)&get_info_log },
	{ "glGetProgramBinary", (void *)&get_program_binary },
	{ "glGetUniformLocation", (void *)&get_location },
	{ "glGetAttribLocation", (void *)&get_location },
	{ "glGetUniformBlockIndex", (void *)&get_block_index },
	{ "glCheckFramebufferStatus", (void *)&check_framebuffer_status },
	{ "glMapBufferRange", (void *)&map_buffer_range },
	{ "glUnmapBuffer", (void *)&unmap_buffer },
	{ "glFenceSync", (void *)&fence_sync },
	{ "glClientWaitSync", (void *)&client_wait_sync },
	{ "glGetSynciv", (void *)&get_synciv },
	{ "glGetQueryObjectui64v", (void *)&get_query_ui64v },
	{ "glGetQueryObjectuiv", (void *)&get_query_uiv },
};

bool enabled() {
	static int on = -1;
	if (on < 0) {
		const char *fabric = getenv("MISTER_FABRIC");
		const char *e = getenv("MISTER_NULL_GL");
		on = (fabric != nullptr && fabric[0] == '1' && !(e != nullptr && e[0] == '0')) ? 1 : 0;
	}
	return on == 1;
}

void *get_proc(const char *p_name) {
	for (const Entry &e : ENTRIES) {
		if (strcmp(e.name, p_name) == 0) {
			return e.fn;
		}
	}
	return (void *)&gl_zero;
}

} // namespace MisterNullGL
