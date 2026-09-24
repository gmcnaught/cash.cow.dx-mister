/**************************************************************************/
/*  mister_framelog.h                                                     */
/*  MISTER: per-frame timing log for stutter analysis (measurement only). */
/*                                                                        */
/*   MISTER_FRAMELOG=/tmp/frames.bin   enable; binary records, see below  */
/*                                                                        */
/*  One MisterFrameRecord per Main::iteration, appended in blocks of 128  */
/*  (write() to the path; put it on tmpfs). Off (env unset) it costs one  */
/*  branch per mark. Decoder: scripts/stutter/frames.py.                  */
/**************************************************************************/

#ifndef MISTER_FRAMELOG_H
#define MISTER_FRAMELOG_H

#include <stdint.h>

// All times in microseconds. t0 is CLOCK_MONOTONIC (aligns with `perf -k mono`).
struct MisterFrameRecord {
	uint64_t t0; // iteration start
	uint32_t gap; // previous record's end -> t0 (OS run loop: events, joypads)
	uint32_t physics; // physics steps loop
	uint32_t process; // SceneTree process + message queue flush
	uint32_t draw; // RenderingServer sync + draw (includes present)
	uint32_t present; // fabric present inside draw (submit + C_DONE wait + pace sleep)
	uint32_t pace; // of which: the fabric library's 59.92 Hz pacing sleep
	uint32_t tail; // script frame() + AudioServer update + bookkeeping
	uint32_t delay; // frame limiter sleep (add_frame_delay)
	uint32_t cpu; // main-thread CPU time, t0 -> end of delay
	uint16_t steps; // physics steps this frame
	uint16_t nvcsw; // voluntary context switches (blocked / slept)
	uint16_t nivcsw; // involuntary context switches (preempted)
	uint16_t minflt; // minor page faults
	uint16_t majflt; // major page faults (disk reads)
	uint16_t cpu_id; // CPU the main thread ended the frame on
	uint32_t nodes; // scene tree node count
	uint32_t scan; // core scanout frame counter right after the fabric publish (0 = n/a)
}; // 64 bytes

namespace MisterFramelog {

extern bool enabled;
extern uint64_t present_us; // accumulated by the fabric bridge during draw
extern uint64_t pace_us; // of which pacing sleep
extern uint32_t scan; // scanout counter after this frame's publish

void init();
void begin(); // iteration start
void mark_physics(int p_steps);
void mark_process();
void mark_draw();
void mark_tail();
void end(uint32_t p_nodes); // after the frame limiter
uint64_t now_us();

} // namespace MisterFramelog

#endif // MISTER_FRAMELOG_H
