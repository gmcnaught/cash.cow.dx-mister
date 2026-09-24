/**************************************************************************/
/*  audio_driver_mister.h                                                 */
/**************************************************************************/
/* MiSTer audio: no Linux sound path under a core. The core's gm_audio    */
/* drains a DDR3 ring of 48 kHz stereo S16 frames into the MiSTer audio   */
/* output; "playing" means copying into the ring and advancing the write  */
/* pointer the FPGA polls.                                                */
/*                                                                        */
/* Ring contract (gm_audio.sv; donut.dodo patches/0004):                  */
/*   0x3A000030  wr_ptr  byte offset into the ring; we own it             */
/*   0x3A000038  rd_ptr  byte offset; the FPGA owns it                    */
/*   0x3A0D0000  ring    65,536 bytes = 16,384 stereo frames              */
/* The rate must equal gm_audio's SRC_RATE (48000 on the Donut Dodo core).*/
/**************************************************************************/

#ifndef AUDIO_DRIVER_MISTER_H
#define AUDIO_DRIVER_MISTER_H

#include "servers/audio_server.h"

#include "core/os/mutex.h"
#include "core/os/thread.h"
#include "core/templates/safe_refcount.h"

class AudioDriverMister : public AudioDriver {
	Thread thread;
	Mutex mutex;

	int mem_fd = -1;
	volatile uint8_t *base = nullptr;
	uint32_t local_wr = 0;

	int32_t *samples_in = nullptr;
	int16_t *samples_out = nullptr;
	uint32_t period_frames = 512;
	uint32_t target_periods = 3;

	SafeFlag active;
	SafeFlag exit_thread;

	// MISTER_AUDIO_STATS=N: print ring depth / mix time every N periods.
	int stats_every = 0;

	static void thread_func(void *p_udata);
	uint32_t _used_bytes() const;
	void _write(const int16_t *p_src, uint32_t p_bytes);

public:
	virtual const char *get_name() const override { return "MiSTer"; }

	virtual Error init() override;
	virtual void start() override;
	virtual int get_mix_rate() const override { return 48000; }
	virtual SpeakerMode get_speaker_mode() const override { return SPEAKER_MODE_STEREO; }
	virtual float get_latency() override;

	virtual void lock() override;
	virtual void unlock() override;
	virtual void finish() override;
};

#endif // AUDIO_DRIVER_MISTER_H
