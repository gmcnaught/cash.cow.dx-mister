/**************************************************************************/
/*  mister_framelog.cpp                                                   */
/*  MISTER: per-frame timing log for stutter analysis (measurement only). */
/**************************************************************************/

#include "mister_framelog.h"

#if defined(__linux__)
#include <fcntl.h>
#include <sched.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#endif

namespace MisterFramelog {

bool enabled = false;
uint64_t present_us = 0;
uint64_t pace_us = 0;
uint32_t scan = 0;

#if defined(__linux__)
static int fd = -1;
static const int BLOCK = 128;
static MisterFrameRecord buf[BLOCK];
static int n = 0;
static MisterFrameRecord cur;
static uint64_t mark = 0;
static uint64_t last_end = 0;
static uint64_t cpu0 = 0;
static struct rusage ru0;

static uint64_t thread_cpu_us() {
	struct timespec ts;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000;
}

uint64_t now_us() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000;
}

static uint32_t lap() {
	const uint64_t t = now_us();
	const uint32_t d = (uint32_t)(t - mark);
	mark = t;
	return d;
}

void init() {
	const char *path = getenv("MISTER_FRAMELOG");
	if (!path || !*path) {
		return;
	}
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	enabled = fd >= 0;
}

void begin() {
	static bool tried = false;
	if (!tried) {
		tried = true;
		init();
	}
	if (!enabled) {
		return;
	}
	cur = MisterFrameRecord();
	mark = now_us();
	cur.t0 = mark;
	cur.gap = last_end ? (uint32_t)(mark - last_end) : 0;
	cpu0 = thread_cpu_us();
	getrusage(RUSAGE_THREAD, &ru0);
	present_us = 0;
	pace_us = 0;
}

void mark_physics(int p_steps) {
	if (enabled) {
		cur.physics = lap();
		cur.steps = (uint16_t)p_steps;
	}
}

void mark_process() {
	if (enabled) {
		cur.process = lap();
	}
}

void mark_draw() {
	if (enabled) {
		cur.draw = lap();
		cur.present = (uint32_t)present_us;
		cur.pace = (uint32_t)pace_us;
		cur.scan = scan;
	}
}

void mark_tail() {
	if (enabled) {
		cur.tail = lap();
	}
}

void end(uint32_t p_nodes) {
	if (!enabled) {
		return;
	}
	cur.delay = lap();
	last_end = mark;
	cur.cpu = (uint32_t)(thread_cpu_us() - cpu0);
	struct rusage ru;
	getrusage(RUSAGE_THREAD, &ru);
	cur.nvcsw = (uint16_t)(ru.ru_nvcsw - ru0.ru_nvcsw);
	cur.nivcsw = (uint16_t)(ru.ru_nivcsw - ru0.ru_nivcsw);
	cur.minflt = (uint16_t)(ru.ru_minflt - ru0.ru_minflt);
	cur.majflt = (uint16_t)(ru.ru_majflt - ru0.ru_majflt);
	cur.cpu_id = (uint16_t)sched_getcpu();
	cur.nodes = p_nodes;
	buf[n++] = cur;
	if (n == BLOCK) {
		// tmpfs: ~7.5 KB, tens of microseconds; charged to the next frame's gap.
		ssize_t w = write(fd, buf, sizeof(buf));
		(void)w;
		n = 0;
	}
}
#else
uint64_t now_us() { return 0; }
void init() {}
void begin() {}
void mark_physics(int) {}
void mark_process() {}
void mark_draw() {}
void mark_tail() {}
void end(uint32_t) {}
#endif

} // namespace MisterFramelog
