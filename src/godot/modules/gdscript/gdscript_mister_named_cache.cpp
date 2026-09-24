/**************************************************************************/
/*  gdscript_mister_named_cache.cpp                                       */
/**************************************************************************/
/* MiSTer: per-instruction inline cache for OPCODE_GET_NAMED /            */
/* OPCODE_SET_NAMED on objects (PLAN §6.16).                              */
/*                                                                        */
/* In Godot 4.3 `obj.prop` (and implicit-self native properties such as   */
/* `visible`) is resolved by name on every execution: GDScriptInstance    */
/* probes the member table, then per script level the constants, static   */
/* variables, signals, methods, subclasses and _get/_set, then ClassDB     */
/* probes property/constant/method/signal maps per native class level -   */
/* ~20 hash lookups, 1.5-2.6 us per access on the Cortex-A9.              */
/*                                                                        */
/* Each GET/SET_NAMED site gets one cache entry keyed by (object class,   */
/* GDScript). The entry is only filled with a fast path where the full    */
/* lookup provably ends in the same place:                                */
/*   MEMBER: a script member without getter/setter -> members[i].         */
/*           (set: only when the value already has the member's type;     */
/*           conversions and errors take the slow path)                   */
/*   NATIVE: no script level resolves the name (no member, constant,      */
/*           static, signal, method, subclass, no _get/_set) and the      */
/*           first native class level that knows the name has a plain     */
/*           property getter/setter MethodBind -> call it exactly as      */
/*           ClassDB::get_property/set_property does.                     */
/* Everything else is marked UNCACHEABLE for that key (slow path). Only   */
/* used on the main thread, so an entry is never read while another       */
/* thread fills it. Scripts are held by Ref so a cached GDScript address  */
/* cannot be reused by a different script.                                */
/**************************************************************************/

#include "gdscript.h"
#include "gdscript_function.h"

#include "core/object/class_db.h"
#include "core/os/thread.h"

#include <stdlib.h>

// Off unless MISTER_GD_CACHE=1: measured no steady-state gain (PLAN §6.16), and one
// run showed a sustained catch-up spiral that no run without the cache has shown.
static bool _mister_cache_enabled() {
	static int on = -1;
	if (unlikely(on < 0)) {
		const char *e = getenv("MISTER_GD_CACHE");
		on = (e != nullptr && e[0] == '1') ? 1 : 0;
	}
	return on == 1;
}

static const uint8_t MISTER_MAX_MISSES = 4;

GDScriptFunction::MisterNamedCache &GDScriptFunction::_mister_slot(int p_ip) const {
	if (unlikely(mister_named_cache == nullptr)) {
		mister_named_cache = memnew_arr(MisterNamedCache, _code_size);
	}
	return mister_named_cache[p_ip];
}

static _FORCE_INLINE_ bool _mister_key(Object *p_obj, GDScriptInstance *&r_gdi, const GDScript *&r_script) {
	// GDExtension objects (Object::_extension) are excluded at fill time via
	// ClassInfo::gdextension, since Object::_get_extension() is protected.
	ScriptInstance *si = p_obj->get_script_instance();
	if (si == nullptr) {
		r_gdi = nullptr;
		r_script = nullptr;
		return true;
	}
	if (si->get_language() != GDScriptLanguage::get_singleton()) {
		return false;
	}
	r_gdi = static_cast<GDScriptInstance *>(si);
	return true;
}

void GDScriptFunction::_mister_fill(MisterNamedCache &e, Object *p_obj, GDScriptInstance *p_gdi, const StringName &p_name, bool p_set) const {
	e.cls = &p_obj->get_class_name();
	e.script = p_gdi ? p_gdi->script.ptr() : nullptr;
	e.script_ref = p_gdi ? Ref<Script>(p_gdi->script) : Ref<Script>();
	e.method = nullptr;
	e.member = nullptr;
	e.kind = MisterNamedCache::UNCACHEABLE;

	const GDScript *scr = static_cast<const GDScript *>(e.script);
	if (scr) {
		HashMap<StringName, GDScript::MemberInfo>::ConstIterator E = scr->member_indices.find(p_name);
		if (E) {
			if (E->value.getter || E->value.setter) {
				return;
			}
			e.member = &E->value; // HashMap elements are separately allocated: stable address.
			e.kind = MisterNamedCache::MEMBER;
			return;
		}
		const StringName &special = p_set ? GDScriptLanguage::get_singleton()->strings._set : GDScriptLanguage::get_singleton()->strings._get;
		for (const GDScript *s = scr; s; s = s->_base) {
			if (!s->valid) {
				return; // Keep it simple: never cache against an invalid script.
			}
			if (s->static_variables_indices.has(p_name) || s->member_functions.has(special)) {
				return;
			}
			if (!p_set && (s->constants.has(p_name) || s->_signals.has(p_name) || s->member_functions.has(p_name) || s->subclasses.has(p_name))) {
				return;
			}
		}
	}

	ClassDB::ClassInfo *check = ClassDB::classes.getptr(*e.cls);
	while (check) {
		if (check->gdextension) {
			return; // Extension classes have their own get/set hooks (Object::_extension).
		}
		const ClassDB::PropertySetGet *psg = check->property_setget.getptr(p_name);
		if (psg) {
			if (psg->index >= 0) {
				return;
			}
			if (p_set) {
				if (psg->setter == StringName() || psg->_setptr == nullptr) {
					return;
				}
				e.method = psg->_setptr;
			} else {
				if (psg->getter == StringName() || psg->_getptr == nullptr) {
					return;
				}
				e.method = psg->_getptr;
			}
			e.kind = MisterNamedCache::NATIVE;
			return;
		}
		if (!p_set && (check->constant_map.has(p_name) || check->method_map.has(p_name) || check->signal_map.has(p_name))) {
			return;
		}
		check = check->inherits_ptr;
	}
}

bool GDScriptFunction::_mister_named_get(int p_ip, const Variant *p_src, const StringName &p_name, Variant *r_dst) const {
	if (!_mister_cache_enabled() || !Thread::is_main_thread()) {
		return false;
	}
	Object *obj = p_src->get_validated_object();
	if (obj == nullptr) {
		return false;
	}
	GDScriptInstance *gdi = nullptr;
	const GDScript *scr = nullptr;
	if (!_mister_key(obj, gdi, scr)) {
		return false;
	}
	scr = gdi ? gdi->script.ptr() : nullptr;
	MisterNamedCache &e = _mister_slot(p_ip);
	if (e.cls != &obj->get_class_name() || e.script != scr || e.kind == MisterNamedCache::EMPTY) {
		if (e.misses > MISTER_MAX_MISSES) {
			return false; // Megamorphic site: refilling would cost more than the slow path.
		}
		e.misses++;
		_mister_fill(e, obj, gdi, p_name, false);
	}
	switch (e.kind) {
		case MisterNamedCache::MEMBER: {
			// Copy first: dst may be the slot holding the last reference to obj.
			Variant v = gdi->members[static_cast<const GDScript::MemberInfo *>(e.member)->index];
			*r_dst = v;
			return true;
		}
		case MisterNamedCache::NATIVE: {
			Callable::CallError ce;
			Variant v = e.method->call(obj, nullptr, 0, ce);
			*r_dst = v;
			return true;
		}
		default:
			return false;
	}
}

bool GDScriptFunction::_mister_named_set(int p_ip, Variant *p_dst, const StringName &p_name, const Variant *p_value) const {
	if (!_mister_cache_enabled() || !Thread::is_main_thread()) {
		return false;
	}
	Object *obj = p_dst->get_validated_object();
	if (obj == nullptr) {
		return false;
	}
	GDScriptInstance *gdi = nullptr;
	const GDScript *scr = nullptr;
	if (!_mister_key(obj, gdi, scr)) {
		return false;
	}
	scr = gdi ? gdi->script.ptr() : nullptr;
	MisterNamedCache &e = _mister_slot(p_ip);
	if (e.cls != &obj->get_class_name() || e.script != scr || e.kind == MisterNamedCache::EMPTY) {
		if (e.misses > MISTER_MAX_MISSES) {
			return false; // Megamorphic site: refilling would cost more than the slow path.
		}
		e.misses++;
		_mister_fill(e, obj, gdi, p_name, true);
	}
	switch (e.kind) {
		case MisterNamedCache::MEMBER: {
			const GDScript::MemberInfo *mi = static_cast<const GDScript::MemberInfo *>(e.member);
			if (mi->data_type.has_type && !mi->data_type.is_type(*p_value)) {
				return false; // Conversion or error: slow path.
			}
			gdi->members.write[mi->index] = *p_value;
			return true;
		}
		case MisterNamedCache::NATIVE: {
			// Report handled even if the setter call fails: returning false would
			// run the setter again on the slow path. (Debug builds therefore skip
			// the "invalid assignment" break for a failed native setter call.)
			const Variant *args[1] = { p_value };
			Callable::CallError ce;
			e.method->call(obj, args, 1, ce);
			return true;
		}
		default:
			return false;
	}
}
