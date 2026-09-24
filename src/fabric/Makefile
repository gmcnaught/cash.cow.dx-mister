# Cross-build of libmisterfabric.so (armhf, Cortex-A9): the vendored mfgpu
# RasterBackend behind the C ABI in mister_fabric.h, dlopened by the engine.
# Run inside godot4-armhf-build:bullseye with the project mounted, e.g.
#   docker run --rm -v "$PWD":/p -w /p/src/fabric godot4-armhf-build:bullseye make

CROSS   ?= arm-linux-gnueabihf-
CXX      = $(CROSS)g++
CC       = $(CROSS)gcc

VENDOR   = ../vendor
OUT     ?= ../../work/build/fabric

# Framebuffer geometry is a wire contract with the core's blitter_defs.vh and
# the vendored refmodel (see ../vendor/VENDOR.md).
FB_W    ?= 320
FB_H    ?= 240

ARCHFLAGS = -march=armv7-a -marm -mfpu=neon -mtune=cortex-a9 -mfloat-abi=hard
DEFS      = -DMISTER_BUILD=1 -DMISTER_NATIVE_VIDEO=1 -DMISTER_WIDTH=$(FB_W) -DMISTER_HEIGHT=$(FB_H)
INCS      = -I. -I$(VENDOR)/mister -I$(VENDOR)/mfgpu/host -I$(VENDOR)/mfgpu/refmodel
WARN      = -Wall -Wno-unused-function -Wno-unused-variable
COMMON    = -O2 -fPIC $(ARCHFLAGS) $(DEFS) $(INCS) $(WARN)
CXXFLAGS  = $(COMMON) -std=gnu++14 -fno-exceptions -fno-rtti
CFLAGS    = $(COMMON) -std=gnu11

CXX_SRC = mister_fabric.cpp \
          $(VENDOR)/mister/raster_backend_mfgpu.cpp \
          $(VENDOR)/mister/raster_backend_sw.cpp \
          $(VENDOR)/mister/blitter_raster.cpp
C_SRC   = $(VENDOR)/mfgpu/host/blt_emitter.c \
          $(VENDOR)/mfgpu/host/blt_alloc.c \
          $(VENDOR)/mfgpu/refmodel/blitter_ref.c \
          $(VENDOR)/mfgpu/refmodel/blt_tri.c \
          $(VENDOR)/mister/native_video_writer.c

OBJS = $(patsubst %,$(OUT)/%.o,$(notdir $(CXX_SRC) $(C_SRC)))
vpath %.cpp . $(VENDOR)/mister
vpath %.c $(VENDOR)/mfgpu/host $(VENDOR)/mfgpu/refmodel $(VENDOR)/mister

all: $(OUT)/libmisterfabric.so

$(OUT):
	mkdir -p $@

$(OUT)/%.cpp.o: %.cpp | $(OUT)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(OUT)/%.c.o: %.c | $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@

$(OUT)/libmisterfabric.so: $(OBJS)
	$(CXX) -shared -o $@ $^ -lpthread -Wl,--no-undefined -Wl,-soname,libmisterfabric.so
	@echo built $@

clean:
	rm -rf $(OUT)

.PHONY: all clean
