/**************************************************************************/
/*  joypad_mister.cpp                                                     */
/**************************************************************************/
/* See joypad_mister.h.                                                   */
/*                                                                        */
/* Environment:                                                           */
/*   MISTER_JOY=1              enable (also disables JoypadLinux, which   */
/*                             would open the grabbed pad and see nothing)*/
/*   MISTER_JOY_BASE=0x3BF40000  core's joystick region (per-core; the    */
/*                             Maldita/Donut Dodo fabric core relocates   */
/*                             it here; a wrong base is silent)           */
/*   MISTER_JOY_PLAYERS=1      number of pads (1..2)                      */
/*   MISTER_JOY_DEBUG=1        print every word change                    */
/**************************************************************************/

#include "joypad_mister.h"

#include "core/input/input.h"
#include "core/string/print_string.h"

#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static const uint32_t JOY_BASE_DEFAULT = 0x3BF40000;
static const uint32_t JOY_MAP_LEN = 0x1000;
static const uint32_t JOY_OFFSETS[2] = { 0x008, 0x018 };

// Word bit (4 + i) -> Godot JoyButton. The GUID below is not in Godot's
// controller database, so Input passes these indices through unmapped, and
// the game's InputMap (A=0 jump/accept, B=1 cancel, BACK=4 select,
// START=6 start/pause, DPAD 11..14) sees them directly.
static const JoyButton JOY_BUTTONS[8] = {
	JoyButton::A, // Jump/OK
	JoyButton::B, // Back
	JoyButton::X, // Unused
	JoyButton::Y, // Options
	JoyButton::START, // Start
	JoyButton::BACK, // Select/Coin
	JoyButton::LEFT_SHOULDER, // L
	JoyButton::RIGHT_SHOULDER, // R
};
static const JoyButton JOY_DPAD[4] = {
	JoyButton::DPAD_RIGHT, // bit0
	JoyButton::DPAD_LEFT, // bit1
	JoyButton::DPAD_DOWN, // bit2
	JoyButton::DPAD_UP, // bit3
};

bool JoypadMister::is_enabled() {
	const char *env = getenv("MISTER_JOY");
	return env != nullptr && *env == '1';
}

JoypadMister::JoypadMister() {
	if (!is_enabled()) {
		return;
	}
	uint32_t base = JOY_BASE_DEFAULT;
	const char *env = getenv("MISTER_JOY_BASE");
	if (env != nullptr && *env != '\0') {
		uint32_t v = (uint32_t)strtoul(env, nullptr, 0);
		if (v != 0) {
			base = v;
		}
	}
	env = getenv("MISTER_JOY_DEBUG");
	debug = env != nullptr && *env == '1';

	mem_fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (mem_fd < 0) {
		ERR_PRINT("MiSTer joystick: cannot open /dev/mem (root required); no pads.");
		return;
	}
	void *map = mmap(nullptr, JOY_MAP_LEN, PROT_READ, MAP_SHARED, mem_fd, base);
	if (map == MAP_FAILED) {
		close(mem_fd);
		mem_fd = -1;
		ERR_PRINT(vformat("MiSTer joystick: mmap of 0x%08x failed; no pads.", base));
		return;
	}
	ddr = (volatile uint8_t *)map;

	env = getenv("MISTER_JOY_PLAYERS");
	int want = CLAMP(env ? atoi(env) : 1, 1, MAX_PADS);
	Input *input = Input::get_singleton();
	for (int i = 0; i < want; i++) {
		int id = input->get_unused_joy_id();
		if (id < 0) {
			break;
		}
		device_id[i] = id;
		offset[i] = JOY_OFFSETS[i];
		last_word[i] = 0;
		// Never reported disconnected: the game pauses on a disconnect.
		input->joy_connection_changed(id, true, vformat("MiSTer Joystick %d", i + 1), vformat("4d695354657200000000000000000%03d", i));
		npads++;
	}
	print_line(vformat("MiSTer joystick: %d pad(s) from DDR joystick words at 0x%08x.", npads, base));
}

void JoypadMister::poll() {
	if (ddr == nullptr) {
		return;
	}
	Input *input = Input::get_singleton();
	for (int i = 0; i < npads; i++) {
		uint32_t word = *(volatile uint32_t *)(ddr + offset[i]);
		uint32_t changed = word ^ last_word[i];
		if (changed == 0) {
			continue;
		}
		if (debug) {
			print_line(vformat("MiSTer joystick %d: 0x%08x -> 0x%08x", i, last_word[i], word));
		}
		for (int b = 0; b < 4; b++) {
			if (changed & (1u << b)) {
				input->joy_button(device_id[i], JOY_DPAD[b], (word >> b) & 1);
			}
		}
		for (int b = 0; b < 8; b++) {
			if (changed & (1u << (4 + b))) {
				input->joy_button(device_id[i], JOY_BUTTONS[b], (word >> (4 + b)) & 1);
			}
		}
		last_word[i] = word;
	}
}

JoypadMister::~JoypadMister() {
	if (ddr != nullptr) {
		munmap((void *)ddr, JOY_MAP_LEN);
	}
	if (mem_fd >= 0) {
		close(mem_fd);
	}
}
