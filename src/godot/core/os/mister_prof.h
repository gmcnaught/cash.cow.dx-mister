/**************************************************************************/
/*  mister_prof.h                                                         */
/**************************************************************************/
/* MiSTer port: boot cost attribution (MISTER_BOOTLOG). Scopes around the   */
/* load-time primitives accumulate exclusive (self) microseconds per         */
/* category on the main thread; nested scopes are subtracted from their      */
/* parent. mister_prof_dump() appends the cumulative totals to the boot log. */
/* Off (no MISTER_BOOTLOG) = one cached check per scope.                     */
/**************************************************************************/

#pragma once

#include <stdint.h>

enum MisterProfCat {
	MF_RES_LOAD, // ResourceLoader::_load (path remap, loader lookup, cache)
	MF_RES_BINARY, // ResourceLoaderBinary::load (.scn/.res parsing)
	MF_GD_RELOAD, // GDScript::reload outside parse/analyze/compile
	MF_GD_PARSE, // GDScriptParser::parse / parse_binary
	MF_GD_ANALYZE, // GDScriptAnalyzer resolve_* (incl. dependency analysis)
	MF_GD_COMPILE, // GDScriptCompiler::compile
	MF_SCENE_INST, // SceneState::instantiate
	MF_READY, // Node::_propagate_ready (script _ready bodies)
	MF_WEBP, // WebP decode
	MF_OGG_INFO, // AudioStreamOggVorbis::maybe_update_info
	MF_PROF_COUNT
};

bool mister_prof_on();
void mister_prof_dump(const char *p_tag);

struct MisterProfScope {
	MisterProfScope *parent = nullptr;
	uint64_t t0 = 0;
	uint64_t child = 0;
	int cat = 0;
	bool on = false;
	explicit MisterProfScope(int p_cat);
	~MisterProfScope();
};
