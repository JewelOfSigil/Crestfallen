// Prototype 2: the world save (design sections 4, 5, 6, and 13 step 3).
// Saves the world — turfs and atoms — to native BYOND savefiles, one
// per z-level, and overlays a save on top of the fresh map at boot.
//
// File layout (design section 4; the design team's 2026-11-20 answers):
// data/world_saves/[map]/[world]-[YYYYMMDD-HHMMSS]/ — one folder per
// save generation, named for the loaded world and the real-world date.
// Inside a generation: z1.sav, z2.sav, ... (one per map z-level),
// meta.sav (version, map name, date, counts, checksum), and a
// `complete` marker file, written last. Only the latest two
// generations are kept — the live save and its backup; older ones are
// removed after a successful save.
//
// Format rules (design section 4):
// - One savefile per z-level. Turfs are saved as a diff: only
//   turfs whose type changed from the map default are written (see
//   the baseline, below). Season-changed turfs are excluded — the
//   season system re-applies them after the load, so they do not
//   need to be saved (see persistence_is_season_change). Atoms save their type, location, a small
//   allowlist of vars (below), and their contents, recursively.
//   There is no blind dump of everything.
// - Every file carries a format version (min/max, same pattern as the
//   preferences savefile) and a checksum, computed from the saved
//   data, so the loader can tell whether the file was written
//   completely and correctly.
// - Writes are atomic: the generation folder is written complete,
//   then the marker is written last. A missing marker means the save
//   is incomplete, no matter what the files look like.
// - The loader validates before it trusts anything: marker present,
//   version in range, map identity matches, checksum matches. Every
//   z-level file is read and validated before anything is restored,
//   so a corrupt generation never leaves a half-restored world. A
//   corrupt or incomplete save falls back to the previous generation
//   (the backup); if both fail, the failure is logged loudly and the
//   server boots on the fresh map — a hard recovery hold that halts
//   boot is a follow-up, not this slice.
//
// Restore contract (design section 5):
// - Turfs are modified in place: the existing turf at (x, y, z) is
//   ChangeTurf'd to the saved type.
// - Atoms are deleted and recreated: every in-scope atom on the map
//   is removed, then each saved atom is built with `new type(loc)`
//   before its saved values are applied. Atom identity is not
//   preserved across the reboot, which is fine at boot — no mob holds
//   references yet, and machines re-register when created.
// - Do NOT save (and do not recreate): loot spawners (they stay on
//   the map from the fresh map and fire again only if the loot was
//   taken — see the spawner's own should_spawn check — so loot
//   replenishes on restart instead of accumulating endlessly),
//   landmarks, and mapping helpers (they self-delete after loading).
// - Mobs are NOT saved here: player characters have their own
//   character saves, and spawned NPC mobs are designed to despawn
//   (they reset each round).
// - Season state is NOT saved in this slice: the season is derived
//   from the calendar as today, and restored turfs re-register in the
//   season's tracking lists through their own Initialize/Destroy, so
//   the season system converts them as the calendar rolls over.
//
// Sequencing (design section 6):
// - Saving runs in declare_completion(), before the reboot, and in
//   the Test World Save verb. The character save runs at the same
//   point (both are wired in declare_completion()).
// - Loading is a load-on-boot overlay: SSmapping calls it right after
//   loadWorld(), before SSatoms initialises the map-loaded atoms.
//
// This code has not been compiled: BYOND cannot run on this machine.
// Compile it locally with tools/build/build.bat (BYOND 516.1687, the
// version the repo pins) before trusting any of it.

#define WORLD_SAVE_VERSION_MIN 1
#define WORLD_SAVE_VERSION_MAX 1

// Atom types never saved (and never recreated). Loot spawners fire at
// round start, so saving them would double-spawn loot; landmarks and
// mapping helpers self-delete after loading. A gate's blockers are
// derived state — the gate rebuilds them in its Initialize — so
// saving them would duplicate them on load, and an orphan blocker
// stays dense forever, blocking the gate's turfs even when it is open.
GLOBAL_LIST_INIT(persistence_world_skip_types, list(
	/obj/effect/spawner/lootdrop,
	/obj/effect/landmark,
	/obj/gblock,
))

/* True while a world save is being restored (the atoms are being
recreated). Structures whose Initialize kicks off a delayed open or
close — a bars gate closing itself, a preopen gate opening itself —
skip that while this is set, so a gate keeps the state it was saved
in instead of flipping itself a second after boot. The post-load
re-link (persistence_relink_gates) syncs the blockers to the saved
state instead. Implemented with AI architecting. */
GLOBAL_VAR_INIT(persistence_restoring_world, FALSE)

/* Per-type extra vars, by typepath. A mineral door's open/closed and
locked state live in its own vars, not in density, so they are
saved explicitly — as are its lock id and hash, which are plain
values (not references) and are what a key matches against. More
types gain entries here as they need them. The list is built up
instead of returning early, so a type can carry both the general
entries (a structure's redstone id) and its own (a gate's gid).
Ids are only added when set, so structures without one do not bloat
the save with a null entry. Implemented with AI architecting. */
/proc/persistence_world_type_vars(obj/O)
	var/list/vars = list()
	// A structure's redstone id is the plain-string link between a
	// trigger (lever, pressure plate) and a reaction (grille,
	// passage, shutter). The attached-object references do not
	// survive a savefile, so the id is saved and the link rebuilt
	// after the load (see persistence_relink_redstone).
	if(istype(O, /obj/structure) && O.vars["redstone_id"])
		vars += list("redstone_id")
	if(istype(O, /obj/structure/mineral_door))
		vars += list("door_opened", "locked", "lockid", "lockhash", "grant_resident_key")
	// A key lying in the world (in a chest, on a table) keeps its
	// lock id and hash the same way a carried one does.
	if(istype(O, /obj/item/roguekey))
		vars += list("lockid", "lockhash")
	// Tent kits and their components. The kit's assembled state, its
	// stable id, its repair debts, and its roof's turf coordinates
	// (as "x,y,z" strings) are saved, so a load can re-link the kit
	// to the walls, doors, and roof it placed. A component saves the
	// owning kit's id (the reference itself does not survive a
	// savefile) and its integrity, so a damaged wall stays damaged.
	if(istype(O, /obj/item/tent_kit))
		vars += list("assembled", "tent_id", "repair_debt_cloth", "repair_debt_silk", "parts_destroyed_count", "roof_turf_coords", "roof_tile_coords")
	if(istype(O, /obj/structure/tent_component))
		vars += list("parent_tent_id", "obj_integrity")
	// Beds: who claimed this bed as their home. A bed is a world
	// atom, so without this the claim would reset on every restart
	// and the character's saved home would point at a bed that no
	// longer knows them. tavern_property is a type default, not
	// instance state, so it needs no entry here.
	if(istype(O, /obj/structure/bed))
		vars += list("claimed_by")
	// A floor grille's open/closed state (togg) and whether it is
	// broken. Without these an open grille comes back closed, and a
	// broken one comes back whole enough to be a platform again —
	// the icon alone (a generic var) shows the state but does not
	// restore the platform flags behind it.
	if(istype(O, /obj/structure/bars/grille))
		vars += list("togg", "obj_broken")
	// A floor hatch's open/closed state (togg) and whether it is
	// broken — same pattern as a grille. Without these an open
	// hatch comes back looking open but behaving closed, and a
	// broken one comes back a platform again.
	if(istype(O, /obj/structure/floordoor))
		vars += list("togg", "obj_broken")
	// A lever's pulled/unpulled state. Its icon is a generic var,
	// but the var behind it decides what the next pull does.
	if(istype(O, /obj/structure/lever))
		vars += list("toggled")
	// A gate's and a winch's gid is the plain-string link between
	// them (the attached_gate/attached_to references do not survive
	// a savefile). Without it every winch matches the first gate
	// after a load, because a missing gid is null on both sides.
	if(istype(O, /obj/structure/gate) && O.vars["gid"])
		vars += list("gid")
	if(istype(O, /obj/structure/winch) && O.vars["gid"])
		vars += list("gid")
	if(!length(vars))
		return null
	return vars

// The loaded world's name, sanitised for a folder name (lowercase
// a-z0-9, like the character-save sanitiser). Falls back to "world"
// if the map config is not loaded yet. (The global config datum has
// no map_name — it lives on the map config, SSmapping.config.)
/proc/persistence_world_name()
	var/name = SSmapping?.config?.map_name || "world"
	var/sanitized = ""
	for(var/i in 1 to length(name))
		var/ch = copytext(name, i, i + 1)
		if(ch >= "a" && ch <= "z")
			sanitized += ch
		else if(ch >= "A" && ch <= "Z")
			sanitized += lowertext(ch)
		else if(ch >= "0" && ch <= "9")
			sanitized += ch
	if(!length(sanitized))
		sanitized = "world"
	if(length(sanitized) > 64)
		sanitized = copytext(sanitized, 1, 65)
	return sanitized

// Root and per-map save directories.
/proc/persistence_world_save_root()
	return "data/world_saves/"

/proc/persistence_world_map_dir()
	return "[persistence_world_save_root()][persistence_world_name()]/"

// A generation folder name: [world]-[YYYYMMDD-HHMMSS], real-world
// date and time, so generations sort in time order.
/proc/persistence_world_generation_name()
	return "[persistence_world_name()]-[time2text(world.realtime, "YYYYMMDD-hhmmss")]"

// The z-levels of the map file in use: from SSmapping's station_start
// (the first z of the main map) to the last map z. The Transit/Reserved
// level is excluded: it is added after the map loads, so at load time
// world.maxz is already the last map z, but at save time (during play)
// it is the last z overall, so it is cut off here. CentCom (z 1,
// compiled in) is below station_start and is not a map z-level.
// Runtime turf-reservation levels are also excluded: they are marked
// with the ZTRAIT_RESERVED trait and are runtime scratch space, not
// persistent world state, so they are never saved. Away-mission levels
// are excluded the same way: zones loaded as new z-levels (for example
// through /datum/map_template/load_new_z()) are marked with the
// ZTRAIT_AWAY trait, and they are transient exploration or mining
// zones, not persistent world state. Implemented with AI architecting.
/proc/persistence_world_map_zs()
	var/start = SSmapping?.station_start || 1
	var/end = world.maxz
	var/transit_z = SSmapping?.transit?.z_value
	if(transit_z && transit_z <= end)
		end = transit_z - 1
	var/list/zs = list()
	for(var/z in start to end)
		if(SSmapping?.level_trait(z, ZTRAIT_RESERVED))
			continue
		if(SSmapping?.level_trait(z, ZTRAIT_AWAY))
			continue
		zs += z
	return zs

// The map-default turf types, captured at boot right after the map
// loads and before the world save is overlaid (see SSmapping).
// Keyed by a numeric turf key (x + y*1000 + z*1000000). The diff
// save compares each turf's current type against this baseline and
// only writes turfs that changed. Season-changed turfs are excluded
// separately (see persistence_is_season_change). Implemented with AI
// architecting.
GLOBAL_LIST_EMPTY(persistence_baseline_turfs)

// A key for a turf position, for the baseline assoc list. It must
// be a string: a numeric key would be treated as a list index, and
// a turf key (up to the millions) is far beyond the list's length,
// which runtimes as "list index out of bounds".
/proc/persistence_turf_key(x, y, z)
	return "[x],[y],[z]"

// Capture the map-default turf types into the baseline. Runs once at
// boot, after loadWorld() and before the world save is overlaid, so
// the baseline is the fresh map — never the restored world. A turf
// that was changed in an earlier round and restored by the load
// still differs from this baseline, so it is saved again.
/proc/persistence_capture_baseline()
	var/list/zs = persistence_world_map_zs()
	for(var/z in zs)
		var/turf/corner_a = locate(1, 1, z)
		var/turf/corner_b = locate(world.maxx, world.maxy, z)
		for(var/turf/T in block(corner_a, corner_b))
			GLOB.persistence_baseline_turfs[persistence_turf_key(T.x, T.y, T.z)] = T.type
	log_world("Persistence: captured the turf baseline for [length(GLOB.persistence_baseline_turfs)] turfs.")

// Returns TRUE if a turf's change from its baseline (map-default)
// type is a season change, so it does not need to be saved — the
// season system will re-apply it after the load. The check uses the
// current turf instance's own vars (initial() cannot read a var
// from a typepath held in a variable), so it never touches the
// baseline type's vars directly.
// - Winter/summer sibling turfs (paths, grasscold, grassred,
//   grassyel): the current turf and the baseline are a winter/summer
//   pair if either one's sibling var points at the other. The season
//   system is the only thing that converts between a winter form and
//   its summer form.
// - Plain grass turfs: SSseason converts them to a single seasonal
//   target (grass/grassyel/grassred/snow) based on the season.
/proc/persistence_is_season_change(turf/T, baseline_type)
	if(!baseline_type || !ispath(baseline_type, /turf/open/floor/rogue))
		return FALSE
	if(istype(T, /turf/open/floor/rogue))
		var/turf/open/floor/rogue/R = T
		if(R.summer_type == baseline_type || R.winter_type == baseline_type)
			return TRUE
	if(ispath(baseline_type, /turf/open/floor/rogue/grass) && T.type == SSseason.get_target_turf_type())
		return TRUE
	return FALSE

// A short checksum over the saved data, so the loader can tell
// whether the file was written completely. It is a simple additive
// check over coordinates and counts, not a cryptographic hash —
// enough to catch a truncated or half-written file, which the
// completion marker and the version check also guard against.
/proc/persistence_world_checksum(turf_count, atom_count, coord_sum)
	return (turf_count * 1000003 + atom_count * 1009 + coord_sum) % 2147483647

// List the generation folders for the current map, newest first.
// Folder names sort in time order, so sorting descending gives the
// latest generation first. A trailing slash on a directory name
// (which flist may return) is stripped, so the folder name can be
// joined to the map directory cleanly.
/proc/persistence_world_generations()
	var/map_dir = persistence_world_map_dir()
	var/list/names = flist(map_dir)
	var/list/generations = list()
	for(var/name in names)
		if(copytext(name, length(name)) == "/")
			name = copytext(name, 1, length(name))
		if(findtext(name, persistence_world_name()) == 1)
			generations += name
	return sortList(generations, GLOBAL_PROC_REF(cmp_text_dsc))

// Remove all but the latest two generation folders for the current
// map, so only the live save and its backup are kept.
/proc/persistence_world_prune_generations()
	var/list/generations = persistence_world_generations()
	if(length(generations) <= 2)
		return
	var/map_dir = persistence_world_map_dir()
	for(var/i in 3 to length(generations))
		var/generation = generations[i]
		var/dir = "[map_dir][generation]/"
		for(var/file in flist(dir))
			fdel("[dir][file]")
		fdel(dir)
		log_world("Persistence: pruned old world-save generation [generation].")

// ---- Saving ----

// Save the world (turfs and atoms) for the map file in use. Returns
// TRUE on success, FALSE on failure (logged). Writes one savefile per
// map z-level plus a meta file, into a new generation folder, and
// writes the completion marker last. The previous generation is kept
// as the backup; older ones are pruned.
/proc/persistence_save_world()
	var/start = world.realtime
	var/map_name = persistence_world_name()
	var/list/zs = persistence_world_map_zs()
	if(!length(zs))
		log_world("Persistence: world save failed — no map z-levels found.")
		return FALSE
	// Tent kits: give every kit (and its components and roof) a
	// stable id before anything is saved, so a load can re-link
	// them. This also covers kits placed before the tent-id fix,
	// whose components carry no id yet.
	for(var/obj/item/tent_kit/K in world)
		K.ensure_tent_id()
	var/generation = persistence_world_generation_name()
	var/dir = "[persistence_world_map_dir()][generation]/"
	var/turf_total = 0
	var/atom_total = 0
	var/coord_total = 0
	var/list/z_checksums = list()
	for(var/z in zs)
		var/savefile/S = new /savefile("[dir]z[z].sav")
		WRITE_FILE(S["version"], WORLD_SAVE_VERSION_MAX)
		WRITE_FILE(S["map_name"], map_name)
		WRITE_FILE(S["z"], z)
		var/list/turf_entries = list()
		var/list/atom_entries = list()
		var/coord_sum = 0
		// Turfs: a diff against the boot-time baseline. Each entry is
		// a positional list (x, y, type). Only turfs whose type
		// changed from the map default are written. A turf whose
		// change is a season change is not written — the season
		// system re-applies it after the load.
		// A turf with no baseline entry is written (fail-safe: if
		// the baseline is missing, the turf is saved, never lost).
		var/turf/corner_a = locate(1, 1, z)
		var/turf/corner_b = locate(world.maxx, world.maxy, z)
		for(var/turf/T in block(corner_a, corner_b))
			var/baseline = GLOB.persistence_baseline_turfs[persistence_turf_key(T.x, T.y, T.z)]
			if(baseline && T.type == baseline)
				continue
			if(baseline && persistence_is_season_change(T, baseline))
				continue
			turf_entries += list(list(T.x, T.y, T.type))
			coord_sum += T.x + T.y * 1000
		// Atoms: top-level /obj atoms on the turf (contents ride
		// along recursively). Mobs are not saved here.
		for(var/obj/O in world)
			if(O.z != z)
				continue
			if(!isturf(O.loc))
				continue
			if(!persistence_world_should_save_atom(O))
				continue
			atom_entries += list(persistence_world_save_atom(O))
			coord_sum += O.x + O.y * 1000
		WRITE_FILE(S["turfs"], turf_entries)
		WRITE_FILE(S["atoms"], atom_entries)
		WRITE_FILE(S["turf_count"], length(turf_entries))
		WRITE_FILE(S["atom_count"], length(atom_entries))
		var/checksum = persistence_world_checksum(length(turf_entries), length(atom_entries), coord_sum)
		WRITE_FILE(S["checksum"], checksum)
		z_checksums["[z]"] = checksum
		turf_total += length(turf_entries)
		atom_total += length(atom_entries)
		coord_total += coord_sum
	// Meta file: version, map, date, counts, per-z checksums.
	var/savefile/M = new /savefile("[dir]meta.sav")
	WRITE_FILE(M["version"], WORLD_SAVE_VERSION_MAX)
	WRITE_FILE(M["map_name"], map_name)
	WRITE_FILE(M["save_date"], time2text(world.realtime, "YYYY-MM-DD hh:mm:ss"))
	WRITE_FILE(M["z_levels"], zs)
	WRITE_FILE(M["turf_count"], turf_total)
	WRITE_FILE(M["atom_count"], atom_total)
	WRITE_FILE(M["checksum"], persistence_world_checksum(turf_total, atom_total, coord_total))
	WRITE_FILE(M["z_checksums"], z_checksums)
	// The completion marker goes last, only after every file is
	// written. A missing marker means the save is incomplete.
	text2file("complete", "[dir]complete")
	var/duration = round((world.realtime - start) / 10, 0.1)
	log_world("Persistence: world save complete: [turf_total] turfs, [atom_total] atoms across [length(zs)] z-levels, generation [generation], in [duration]s.")
	persistence_world_prune_generations()
	return TRUE

// Whether an atom is saved at all. Loot spawners, landmarks, and
// mapping helpers are never saved.
/proc/persistence_world_should_save_atom(obj/O)
	for(var/skip_type in GLOB.persistence_world_skip_types)
		if(istype(O, skip_type))
			return FALSE
	return TRUE

// Save one atom (and its contents, recursively) as a positional list:
// (type, x, y, vars, contents). Vars is an assoc list of var name to
// value, holding only the generic vars and the type's extra vars that
// differ from the type default. Contents is a list of atom entries in
// the same shape.
/proc/persistence_world_save_atom(obj/O)
	var/list/vars = list()
	// Generic vars, only when they differ from the type default.
	if(O.density != initial(O.density))
		vars["density"] = O.density
	if(O.opacity != initial(O.opacity))
		vars["opacity"] = O.opacity
	if(O.icon_state != initial(O.icon_state))
		vars["icon_state"] = O.icon_state
	if(O.dir != initial(O.dir))
		vars["dir"] = O.dir
	if(O.color != initial(O.color))
		vars["color"] = O.color
	if(O.alpha != initial(O.alpha))
		vars["alpha"] = O.alpha
	if(O.name != initial(O.name))
		vars["name"] = O.name
	// A mapper's pixel offset (a shifted candle, a winch nudged a
	// few pixels) is instance state, not a type default, so it is
	// saved the same way as the other placement vars — otherwise
	// everything snaps back to its grid cell on load.
	if(O.pixel_x != initial(O.pixel_x))
		vars["pixel_x"] = O.pixel_x
	if(O.pixel_y != initial(O.pixel_y))
		vars["pixel_y"] = O.pixel_y
	// Per-type extra vars, saved as they are (they are few, and a
	// door's locked state matters even when it is the default).
	var/list/type_vars = persistence_world_type_vars(O)
	if(length(type_vars))
		for(var/varname in type_vars)
			if(varname in O.vars)
				vars[varname] = O.vars[varname]
	var/list/kids = list()
	for(var/obj/K in O.contents)
		if(!persistence_world_should_save_atom(K))
			continue
		kids += list(persistence_world_save_atom(K))
	return list(O.type, O.x, O.y, vars, kids)

// ---- Loading ----

// Load the latest valid world save for the map file in use and overlay
// it on the fresh map. Called by SSmapping right after loadWorld().
// Returns TRUE if a save was loaded, FALSE if there was none or it
// could not be validated (logged). If the latest generation fails
// validation, the previous generation (the backup) is tried; if both
// fail, the failure is logged loudly and the server boots on the fresh
// map — a hard recovery hold that halts boot is a follow-up.
/proc/persistence_load_world()
	var/map_name = persistence_world_name()
	log_world("Persistence: looking for a world save for [map_name]...")
	var/list/generations = persistence_world_generations()
	if(!length(generations))
		log_world("Persistence: no world save generations found for [map_name]; booting on the fresh map.")
		return FALSE
	log_world("Persistence: found [length(generations)] world save generation(s) for [map_name]; trying the newest first.")
	for(var/generation in generations)
		var/dir = "[persistence_world_map_dir()][generation]/"
		if(!fexists("[dir]complete"))
			log_world("Persistence: world save generation [generation] has no completion marker — incomplete, trying the previous generation.")
			continue
		log_world("Persistence: trying world save generation [generation]...")
		if(persistence_load_generation(dir, map_name))
			log_world("Persistence: world save loaded from generation [generation].")
			return TRUE
		log_world("Persistence: world save generation [generation] failed validation — trying the previous generation.")
	log_world("Persistence: ERROR — no valid world save could be loaded for [map_name]. The server is booting on the fresh map; restore a backup generation by hand if the saved world must be recovered.")
	return FALSE

// Validate and load one generation folder. Returns TRUE on success.
// Every z-level file is read and validated FIRST; only when all of
// them pass are the atoms cleared and the save applied. That way a
// corrupt generation never leaves a half-restored world behind.
/proc/persistence_load_generation(dir, map_name)
	var/savefile/M = new /savefile("[dir]meta.sav")
	var/version = 0
	M["version"] >> version
	if(version < WORLD_SAVE_VERSION_MIN || version > WORLD_SAVE_VERSION_MAX)
		log_world("Persistence: world save version [version] out of range ([WORLD_SAVE_VERSION_MIN]-[WORLD_SAVE_VERSION_MAX]).")
		return FALSE
	var/saved_map = ""
	M["map_name"] >> saved_map
	if(saved_map != map_name)
		log_world("Persistence: world save is for map '[saved_map]', not '[map_name]'.")
		return FALSE
	var/list/zs = list()
	M["z_levels"] >> zs
	if(!length(zs))
		return FALSE
	// Skip any z-level that is not part of the current map's savable
	// set — e.g. runtime reservation levels from an older save, which
	// are no longer saved. They are runtime scratch space, not
	// persistent world state, so there is nothing to restore there;
	// they stay as the fresh map's empty space. Implemented with AI
	// architecting.
	var/list/map_zs = persistence_world_map_zs()
	var/list/filtered = list()
	for(var/z in zs)
		if(z in map_zs)
			filtered += z
	zs = filtered
	if(!length(zs))
		return FALSE
	log_world("Persistence: generation for [map_name] passed the meta check; reading and validating [length(zs)] z-level file(s) ([english_list(zs)])...")
	// Read and validate every z-level before touching the world.
	var/list/z_data = list()
	for(var/z in zs)
		log_world("Persistence: reading z[z] save file...")
		var/list/data = persistence_world_read_z(dir, z)
		if(!data)
			return FALSE
		log_world("Persistence: z[z] validated ([length(data["turfs"])] turf entries, [length(data["atoms"])] atom entries).")
		z_data["[z]"] = data
	// All valid. Remove the in-scope atoms first, so the saved atoms
	// are not duplicated on top of the fresh map's. Landmarks are
	// left alone (they self-delete after loading), and loot spawners
	// are left alone so they can replenish taken loot.
	log_world("Persistence: all z-level files validated; clearing the fresh map's atoms...")
	persistence_world_clear_atoms()
	log_world("Persistence: fresh map's atoms cleared; restoring the saved world...")
	// Suppress container population while the atoms are rebuilt, so a
	// restored container does not fill itself with its defaults on
	// top of its saved contents. The per-item flag (set on each
	// restored container) is the reliable guard, since PopulateContents
	// is deferred a tick; this global flag covers any call that runs
	// synchronously.
	GLOB.persistence_suppress_populate = TRUE
	GLOB.persistence_restoring_world = TRUE
	for(var/z in zs)
		log_world("Persistence: restoring z[z] ([length(z_data["[z]"]["turfs"])] turfs, [length(z_data["[z]"]["atoms"])] atoms)...")
		persistence_world_restore_z(z_data["[z]"], z)
		log_world("Persistence: z[z] restored.")
	GLOB.persistence_suppress_populate = FALSE
	GLOB.persistence_restoring_world = FALSE
	// Tent kits: re-link each restored kit to the walls, doors, and
	// roof it placed. Without this the kit comes back as though
	// unused (a fresh set of components inside it) and its tent
	// becomes a permanent structure with no way to disassemble it.
	persistence_relink_tents()
	// Redstone links and gate/winch links are plain-string ids, and
	// their open/closed state lives in vars the generic save does
	// not cover — rebuild both now that every atom exists.
	persistence_relink_redstone()
	persistence_relink_gates()
	log_world("Persistence: world restore complete for [map_name].")
	return TRUE

// Read one z-level savefile and validate it (version, counts,
// checksum). Returns a list of ("turfs" = turf entries, "atoms" =
// atom entries), or null on failure. Nothing is restored here.
/proc/persistence_world_read_z(dir, z)
	var/savefile/S = new /savefile("[dir]z[z].sav")
	var/version = 0
	S["version"] >> version
	if(version < WORLD_SAVE_VERSION_MIN || version > WORLD_SAVE_VERSION_MAX)
		return null
	var/list/turf_entries = list()
	S["turfs"] >> turf_entries
	var/list/atom_entries = list()
	S["atoms"] >> atom_entries
	var/turf_count = 0
	S["turf_count"] >> turf_count
	var/atom_count = 0
	S["atom_count"] >> atom_count
	var/checksum = 0
	S["checksum"] >> checksum
	if(length(turf_entries) != turf_count || length(atom_entries) != atom_count)
		log_world("Persistence: world save z[z] counts do not match ([length(turf_entries)]/[turf_count] turfs, [length(atom_entries)]/[atom_count] atoms).")
		return null
	var/coord_sum = 0
	for(var/list/entry in turf_entries)
		if(length(entry) < 3)
			continue
		coord_sum += entry[1] + entry[2] * 1000
	for(var/list/entry in atom_entries)
		if(length(entry) < 5)
			continue
		coord_sum += entry[2] + entry[3] * 1000
	if(checksum != persistence_world_checksum(turf_count, atom_count, coord_sum))
		log_world("Persistence: world save z[z] checksum mismatch.")
		return null
	return list("turfs" = turf_entries, "atoms" = atom_entries)

// Apply one z-level of already-validated save data: turfs first (in
// place), then atoms.
/proc/persistence_world_restore_z(list/data, z)
	var/list/turf_entries = data["turfs"]
	var/list/atom_entries = data["atoms"]
	for(var/list/entry in turf_entries)
		if(length(entry) < 3)
			continue
		var/turf/T = locate(entry[1], entry[2], z)
		if(!T)
			continue
		var/turf_type = entry[3]
		if(ispath(turf_type, /turf) && T.type != turf_type)
			T.ChangeTurf(turf_type)
	for(var/list/entry in atom_entries)
		if(length(entry) < 5)
			continue
		persistence_world_restore_atom(entry, z)

// Remove every in-scope atom on the map's z-levels, so the saved
// atoms can be recreated without duplicating the fresh map's.
// Landmarks and loot spawners are left alone: landmarks self-delete
// after loading, and loot spawners stay on the map so they can fire
// again if the loot was taken (their own should_spawn check decides;
// the saved loot is already restored, so a spawner whose loot is
// still there simply does not fire). Contents are removed first, so
// nothing is orphaned. Atoms are collected first and deleted after,
// so deleting does not disturb the iteration.
/proc/persistence_world_clear_atoms()
	var/list/zs = persistence_world_map_zs()
	var/list/to_delete = list()
	for(var/obj/O in world)
		if(!(O.z in zs))
			continue
		if(!isturf(O.loc))
			continue
		if(istype(O, /obj/effect/landmark))
			continue
		if(istype(O, /obj/effect/spawner/lootdrop))
			continue
		to_delete += O
	for(var/obj/O in to_delete)
		persistence_world_delete_atom(O)

// Recursively delete an atom and its contents.
/proc/persistence_world_delete_atom(obj/O)
	var/list/kids = O.contents.Copy()
	for(var/obj/K in kids)
		persistence_world_delete_atom(K)
	qdel(O)

// Re-link tent kits to their components after a load. A kit's walls,
// doors, and roof are tied to it by object references, which do not
// survive a savefile round-trip, so the save records a plain-string
// tent_id on the kit and a parent_tent_id on each component instead.
// This runs after every z-level is restored, so all kits and
// components exist. It discards the fresh components each restored
// kit's Initialize created (they carry no parent_tent_id, so they are
// the duplicates, not the saved ones), rebuilds each kit's lists
// from the restored components, and restores the assembled kit's
// hidden state and roof. A component whose kit is gone stays
// orphaned, as a standalone structure. A component that was crafted
// on its own (a tent door with no kit) carries no id and is left
// alone.
/proc/persistence_relink_tents()
	var/list/kits_by_id = list()
	for(var/obj/item/tent_kit/K in world)
		if(K.tent_id)
			kits_by_id[K.tent_id] = K
	if(!length(kits_by_id))
		return
	for(var/tent_id in kits_by_id)
		var/obj/item/tent_kit/K = kits_by_id[tent_id]
		for(var/obj/structure/tent_component/C in K.contents.Copy())
			if(!C.parent_tent_id)
				qdel(C)
		K.tent_walls.Cut()
		K.tent_doors.Cut()
	for(var/obj/structure/tent_component/C in world)
		var/tent_id = C.parent_tent_id
		if(!tent_id)
			continue
		var/obj/item/tent_kit/K = kits_by_id[tent_id]
		if(!K)
			continue
		K.link_component(C)
	for(var/tent_id in kits_by_id)
		var/obj/item/tent_kit/K = kits_by_id[tent_id]
		K.restore_assembled_state()
		K.restore_roof()

/* Rebuild redstone links after a load, and put each floor grille's
platform back the way its saved state says. A structure's redstone
id is saved (see persistence_world_type_vars), but at the moment it
is created during the restore its id is still the type default, so
its Initialize never registers it and its LateInitialize never
links it — that has to happen here, once every atom exists. A
grille's togg and broken state are saved too, but its platform
flags are not, so they are synced here: open or broken means no
platform, closed and whole means one. Implemented with AI
architecting. */
/proc/persistence_relink_redstone()
	for(var/obj/structure/S in world)
		if(S.redstone_id)
			S.update_redstone_id(S.redstone_id)
	for(var/obj/structure/bars/grille/G in world)
		// Set the flags directly, not via set_is_platform(): at
		// re-link time no turf has initialised yet, so the turf
		// count is 0 and set_is_platform(FALSE) would drive it
		// to -1. The count is built later, by Initialize/Entered,
		// from the flags as set here.
		// Implemented with AI architecting.
		if(G.togg || G.obj_broken)
			G.obj_flags &= ~(BLOCK_Z_OUT_DOWN | BLOCK_Z_IN_UP)
		else
			G.obj_flags |= (BLOCK_Z_OUT_DOWN | BLOCK_Z_IN_UP)
	for(var/obj/structure/floordoor/F in world)
		if(F.togg || F.obj_broken)
			F.obj_flags &= ~(BLOCK_Z_OUT_DOWN | BLOCK_Z_IN_UP)
		else
			F.obj_flags |= (BLOCK_Z_OUT_DOWN | BLOCK_Z_IN_UP)

/* Put each gate back the way it was saved, and re-link every winch
to its gate. A gate's open/closed state is its density, which the
generic save restores — but the blockers it stands on are not
synced by that, and its Initialize always builds them dense, so an
open gate would still block its turfs. Its blockers are also saved
as separate atoms in older saves, so the restore brings back orphan
copies alongside the fresh ones; those are removed here (a blocker
owned by no gate can only be an orphan, since only a gate creates
them). Winches are linked by their gid, which is saved; the link is
rebuilt here rather than left to the winch's LateInitialize, so it
does not depend on the order the atoms were restored in.
Implemented with AI architecting. */
/proc/persistence_relink_gates()
	// Orphan blockers first: any blocker owned by no gate is a
	// leftover from an older save and stays dense forever.
	var/list/owned_blockers = list()
	for(var/obj/structure/gate/G in world)
		for(var/obj/gblock/B in G.blockers)
			owned_blockers |= B
	var/list/orphans = list()
	for(var/obj/gblock/B in world)
		if(!(B in owned_blockers))
			orphans += B
	for(var/obj/gblock/B in orphans)
		qdel(B)
	// Then sync each gate's blockers to its saved density, and
	// re-link each winch to the gate sharing its gid.
	for(var/obj/structure/gate/G in world)
		for(var/obj/gblock/B in G.blockers)
			if(G.density)
				B.density = TRUE
				B.set_opacity(TRUE)
			else
				B.density = FALSE
				B.set_opacity(FALSE)
		G.update_icon()
	for(var/obj/structure/winch/W in world)
		if(!W.gid)
			continue
		for(var/obj/structure/gate/G in GLOB.biggates)
			if(G.gid == W.gid)
				W.attached_gate = G
				G.attached_to = W
				break

// Recreate one saved atom from its entry (type, x, y, vars,
// contents), at the z-level of the file it came from. The atom is
// built with `new type(loc)` before its saved values are applied,
// and its contents are restored after it, each moved into it once
// built. Returns the atom, or null.
/proc/persistence_world_restore_atom(list/entry, z)
	var/atom_type = entry[1]
	if(!ispath(atom_type, /obj))
		return null
	var/turf/loc = locate(entry[2], entry[3], z)
	if(!loc)
		return null
	var/obj/O = new atom_type(loc)
	// A restored container must not fill itself with its defaults on
	// top of its saved contents. The per-item flag is the reliable
	// guard (PopulateContents is deferred a tick); the global flag
	// set around the restore phase covers any synchronous call.
	if(istype(O, /obj/item/storage))
		var/obj/item/storage/S = O
		S.persistence_no_defaults = TRUE
	var/list/vars = entry[4]
	if(length(vars))
		for(var/varname in vars)
			if(varname in O.vars)
				O.vars[varname] = vars[varname]
	// Mark a restored gate so its Initialize (which runs later, in
	// SSatoms) can tell a restored gate from a fresh map gate: only
	// a fresh one takes its subtype's roundstart open/close, and
	// only a restored one gets its blockers synced to its saved
	// density. Implemented with AI architecting.
	if(istype(O, /obj/structure/gate))
		var/obj/structure/gate/G = O
		G.persistence_restored = TRUE
	// A mineral door's lock is a plain id and hash, not a reference.
	// The door's Initialize already ran when it was created above,
	// with a fresh random id and hash that it registered in the
	// globals; the saved values just applied replace them, so
	// register the saved ones instead — otherwise a key created
	// later with this door's id would be given the wrong hash.
	if(istype(O, /obj/structure/mineral_door))
		var/obj/structure/mineral_door/D = O
		if(D.lockid && D.lockhash)
			GLOB.lockids[D.lockid] = D.lockhash
			GLOB.lockhashes |= D.lockhash
	var/list/kids = entry[5]
	if(length(kids))
		for(var/list/kid in kids)
			var/obj/child = persistence_world_restore_atom(kid, z)
			if(child)
				child.forceMove(O)
	return O
