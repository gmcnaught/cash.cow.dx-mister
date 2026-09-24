/**************************************************************************/
/*  audio_driver_mister.cpp                                               */
/**************************************************************************/
/* See audio_driver_mister.h. Select with --audio-driver MiSTer.          */
/*                                                                        */
/* Environment:                                                           */
/*   MISTER_AUDIO_PERIOD=512   frames mixed per period                    */
/*   MISTER_AUDIO_PERIODS=3    target ring depth in periods (latency)     */
/*   MISTER_AUDIO_STATS=N      print ring depth / mix cost every N periods*/
/*   MISTER_PIN_AUDIO=<cpu>    pin the mixer thread to that CPU            */
/**************************************************************************/

#include "audio_driver_mister.h"

#include "core/os/os.h"

#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// MISTER_PIN_*=<cpu>: pin the calling thread to one CPU (PLAN §6.18: the
// launcher runs the engine on CPU1 and gives CPU0 to the main thread alone).
static void mister_pin_self(const char *p_env) {
	const char *e = getenv(p_env);
	if (e == nullptr || *e == '\0') {
		return;
	}
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(atoi(e), &set);
	if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) == 0) {
		print_line(vformat("MiSTer: %s -> CPU%d.", p_env, atoi(e)));
	}
}

static const uint32_t MA_DDR_PHYS_BASE = 0x3A000000;
static const uint32_t MA_MAP_LEN = 0x000E0000; // Pointers and the ring.
static const uint32_t MA_WR_PTR_OFF = 0x00000030;
static const uint32_t MA_RD_PTR_OFF = 0x00000038;
static const uint32_t MA_RING_OFF = 0x000D0000;
static const uint32_t MA_RING_BYTES = 0x00010000;
static const uint32_t MA_RING_MASK = MA_RING_BYTES - 1;
static const uint32_t MA_BYTES_PER_FRAME = 4; // Stereo S16.

uint32_t AudioDriverMister::_used_bytes() const {
	uint32_t rd = *(volatile uint32_t *)(base + MA_RD_PTR_OFF);
	return (local_wr - rd) & MA_RING_MASK;
}

void AudioDriverMister::_write(const int16_t *p_src, uint32_t p_bytes) {
	volatile uint8_t *ring = base + MA_RING_OFF;
	uint32_t off = local_wr & MA_RING_MASK;
	uint32_t tail = MA_RING_BYTES - off;
	if (p_bytes <= tail) {
		memcpy((void *)(ring + off), p_src, p_bytes);
	} else {
		memcpy((void *)(ring + off), p_src, tail);
		memcpy((void *)ring, (const uint8_t *)p_src + tail, p_bytes - tail);
	}
	__sync_synchronize(); // Frames land before the pointer the FPGA polls.
	local_wr = (local_wr + p_bytes) & MA_RING_MASK;
	*(volatile uint32_t *)(base + MA_WR_PTR_OFF) = local_wr;
}

Error AudioDriverMister::init() {
	mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem_fd < 0) {
		ERR_PRINT("MiSTer audio: cannot open /dev/mem (root required).");
		return ERR_CANT_OPEN;
	}
	void *map = mmap(nullptr, MA_MAP_LEN, PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, MA_DDR_PHYS_BASE);
	if (map == MAP_FAILED) {
		close(mem_fd);
		mem_fd = -1;
		ERR_PRINT("MiSTer audio: mmap of the DDR audio ring failed.");
		return ERR_CANT_OPEN;
	}
	base = (volatile uint8_t *)map;

	const char *env = getenv("MISTER_AUDIO_PERIOD");
	if (env != nullptr && atoi(env) > 0) {
		period_frames = CLAMP(atoi(env), 64, 4096);
	}
	env = getenv("MISTER_AUDIO_PERIODS");
	if (env != nullptr && atoi(env) > 0) {
		target_periods = CLAMP(atoi(env), 1, 8);
	}
	env = getenv("MISTER_AUDIO_STATS");
	stats_every = env ? atoi(env) : 0;

	// Start from wherever the FPGA's read pointer is: the ring is then empty,
	// whatever a previous process left behind.
	memset((void *)(base + MA_RING_OFF), 0, MA_RING_BYTES);
	local_wr = *(volatile uint32_t *)(base + MA_RD_PTR_OFF) & MA_RING_MASK & ~(MA_BYTES_PER_FRAME - 1);
	*(volatile uint32_t *)(base + MA_WR_PTR_OFF) = local_wr;

	samples_in = memnew_arr(int32_t, (size_t)period_frames * 2);
	samples_out = memnew_arr(int16_t, (size_t)period_frames * 2);

	print_line(vformat("MiSTer audio: DDR ring, 48000 Hz stereo S16, %d-frame period, %d-period target depth.", period_frames, target_periods));
	thread.start(AudioDriverMister::thread_func, this);
	return OK;
}

void AudioDriverMister::thread_func(void *p_udata) {
	AudioDriverMister *ad = static_cast<AudioDriverMister *>(p_udata);
	mister_pin_self("MISTER_PIN_AUDIO");
	const uint32_t period_bytes = ad->period_frames * MA_BYTES_PER_FRAME;
	const uint32_t target = period_bytes * ad->target_periods;
	const uint32_t max_used = MA_RING_BYTES - MA_BYTES_PER_FRAME - period_bytes;

	uint32_t stat_periods = 0, stat_min_used = UINT32_MAX, stat_underruns = 0;
	uint64_t stat_mix_us = 0;

	while (!ad->exit_thread.is_set()) {
		uint32_t used = ad->_used_bytes();
		// Hold a target depth rather than filling the ring: a full ring starves
		// gm_audio's rate estimate (donut.dodo patches/0004). The FPGA drains
		// one period in ~10.7 ms at 512 frames, so 1 ms naps are cheap.
		if (used > target || used > max_used) {
			OS::get_singleton()->delay_usec(1000);
			continue;
		}
		if (used == 0) {
			stat_underruns++;
		}
		stat_min_used = MIN(stat_min_used, used);

		uint64_t t0 = OS::get_singleton()->get_ticks_usec();
		if (ad->active.is_set()) {
			ad->lock();
			ad->start_counting_ticks();
			ad->audio_server_process(ad->period_frames, ad->samples_in);
			ad->stop_counting_ticks();
			ad->unlock();
			for (uint32_t i = 0; i < ad->period_frames * 2; i++) {
				ad->samples_out[i] = (int16_t)(ad->samples_in[i] >> 16);
			}
		} else {
			memset(ad->samples_out, 0, period_bytes);
		}
		ad->_write(ad->samples_out, period_bytes);

		if (ad->stats_every > 0) {
			stat_mix_us += OS::get_singleton()->get_ticks_usec() - t0;
			if (++stat_periods >= (uint32_t)ad->stats_every) {
				print_line(vformat("MISTER_AUDIO periods=%d mix_ms=%.2f min_depth_frames=%d underruns=%d",
						stat_periods, stat_mix_us / 1000.0 / stat_periods, stat_min_used / MA_BYTES_PER_FRAME, stat_underruns));
				stat_periods = 0;
				stat_mix_us = 0;
				stat_min_used = UINT32_MAX;
				stat_underruns = 0;
			}
		}
	}
}

void AudioDriverMister::start() {
	active.set();
}

float AudioDriverMister::get_latency() {
	return float(period_frames * target_periods) / 48000.0f;
}

void AudioDriverMister::lock() {
	mutex.lock();
}

void AudioDriverMister::unlock() {
	mutex.unlock();
}

void AudioDriverMister::finish() {
	exit_thread.set();
	if (thread.is_started()) {
		thread.wait_to_finish();
	}
	if (base != nullptr) {
		// Leave an empty ring behind: wr = rd.
		*(volatile uint32_t *)(base + MA_WR_PTR_OFF) = *(volatile uint32_t *)(base + MA_RD_PTR_OFF);
		munmap((void *)base, MA_MAP_LEN);
		base = nullptr;
	}
	if (mem_fd >= 0) {
		close(mem_fd);
		mem_fd = -1;
	}
	if (samples_in != nullptr) {
		memdelete_arr(samples_in);
		samples_in = nullptr;
	}
	if (samples_out != nullptr) {
		memdelete_arr(samples_out);
		samples_out = nullptr;
	}
}
