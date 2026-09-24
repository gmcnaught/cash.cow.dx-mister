#!/bin/sh
# Device: run the engine with fabric video, DDR audio and DDR joypad.
#   BIN=godot43aj.cortexa9 JOY_BASE=0x3A0C0000 ./run_play.sh [extra godot args]
# JOY_BASE unset = the real pad (0x3BF40000); 0x3A0C0000 = joy_inject.py.
cd /media/fat/games/cashcow
M=/media/fat/games/gmloader/mesa
exec env LD_LIBRARY_PATH=$M LIBGL_DRIVERS_PATH=$M EGL_PLATFORM=surfaceless GALLIUM_DRIVER=llvmpipe \
  MISTER_FABRIC=1 MISTER_FABRIC_LIB=${FLIB:-$PWD/libmisterfabric.so} GMLOADER_RASTER=mfgpu MISTER_FABRIC_STATS=${FSTATS:-600} \
  MISTER_JOY=1 MISTER_JOY_BASE=${JOY_BASE:-0x3BF40000} MISTER_JOY_DEBUG=${JOY_DEBUG:-0} \
  MISTER_AUDIO_STATS=${ASTATS:-500} \
  GODOT_SILENCE_ROOT_WARNING=1 XDG_DATA_HOME=$PWD/data \
  stdbuf -oL ./${BIN:-godot43aj.cortexa9} --display-driver mister --rendering-driver opengl3_es --audio-driver ${ADRV:-MiSTer} \
  --max-fps 60 --main-pack CashCowDX.pck "$@"
