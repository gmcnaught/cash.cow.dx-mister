/**************************************************************************/
/*  mister_prof.cpp                                                       */
/**************************************************************************/
/* See mister_prof.h.                                                        */
/**************************************************************************/

#include "mister_prof.h"

#include "core/os/thread.h"

#include <stdio.h>
#include <time.h>

bool mister_bootlog_on(); // core/os/os.cpp
void mister_bootlog(const char *p_fmt, ...);

static MisterProfScope *mf_prof_top = nullptr; // main thread only
static uint64_t mf_prof_self[MF_PROF_COUNT];
static uint32_t mf_prof_calls[MF_PROF_COUNT];
static const char *mf_prof_names[MF_PROF_COUNT] = { "res_load", "res_binary", "gd_reload", "gd_parse", "gd_analyze", "gd_compile", "scene_inst", "ready", "webp", "ogg_info" };

static uint64_t mf_now_us() {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return uint64_t(ts.tv_sec) * 1000000u + uint64_t(ts.tv_nsec) / 1000u;
}

bool mister_prof_on() {
	return mister_bootlog_on() && Thread::is_main_thread();
}

MisterProfScope::MisterProfScope(int p_cat) {
	if (!mister_prof_on()) {
		return;
	}
	on = true;
	cat = p_cat;
	parent = mf_prof_top;
	mf_prof_top = this;
	t0 = mf_now_us();
}

MisterProfScope::~MisterProfScope() {
	if (!on) {
		return;
	}
	const uint64_t el = mf_now_us() - t0;
	mf_prof_self[cat] += el > child ? el - child : 0;
	mf_prof_calls[cat]++;
	if (parent) {
		parent->child += el;
	}
	mf_prof_top = parent;
}

void mister_prof_dump(const char *p_tag) {
	if (!mister_prof_on()) {
		return;
	}
	char buf[640];
	int n = 0;
	for (int i = 0; i < MF_PROF_COUNT && n < (int)sizeof(buf) - 48; i++) {
		n += snprintf(buf + n, sizeof(buf) - n, " %s=%.1f/%u", mf_prof_names[i], mf_prof_self[i] / 1000.0, mf_prof_calls[i]);
	}
	mister_bootlog("prof %s%s", p_tag, buf);
}
