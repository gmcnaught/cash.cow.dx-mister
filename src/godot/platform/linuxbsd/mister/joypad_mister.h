/**************************************************************************/
/*  joypad_mister.h                                                       */
/**************************************************************************/
/* MiSTer joystick: the HPS owns the physical pad (exclusive evdev grab), */
/* applies the core's OSD mapping, and the core publishes the resulting   */
/* joystick word into DDR3 every frame. Reading that word is what makes   */
/* the OSD button assignments apply to the game.                          */
/*                                                                        */
/* Word layout: bit0 right, bit1 left, bit2 down, bit3 up, bit4.. the     */
/* core's CONF_STR J1 buttons ("Jump/OK,Back,Unused,Options,Start,        */
/* Select/Coin,Unused L,Unused R").                                       */
/*                                                                        */
/* Port of donut.dodo patches/0005 (SDL mister joystick driver).          */
/**************************************************************************/

#ifndef JOYPAD_MISTER_H
#define JOYPAD_MISTER_H

#include "core/typedefs.h"

class JoypadMister {
	static const int MAX_PADS = 2;

	int mem_fd = -1;
	volatile uint8_t *ddr = nullptr;
	int npads = 0;
	int device_id[MAX_PADS] = { -1, -1 };
	uint32_t offset[MAX_PADS] = {};
	uint32_t last_word[MAX_PADS] = {};
	bool debug = false;

public:
	// MISTER_JOY=1 enables; unset = no pads (and JoypadLinux stays in charge).
	static bool is_enabled();

	void poll(); // Call once per frame, before Input flushes buffered events.

	JoypadMister();
	~JoypadMister();
};

#endif // JOYPAD_MISTER_H
