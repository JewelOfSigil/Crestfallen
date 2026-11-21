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
// - One savefile per z-level. A full sweep for now (every turf on the
//   map's z-levels); a sparse / difference-based save is a later
//   optimisation.
// - Per-type saved-variable lists. Turfs save their type. Atoms save
//   their type, location, a small allowlist of vars (below), and their
//   contents, recursively. There is no blind dump of everything.
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
// - Do NOT save (and do not recreate): loot spawners (they fire at
//   round start; the saved loot is already restored, so the spawners
//   are removed on load and must not fire again), landmarks, and
//   mapping helpers (they self-delete after loading).
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
// mapping helpers self-delete after loading.
GLOBAL_LIST_INIT(persistence_world_skip_types, list(
	/obj/effect/spawner/lootdrop,
	/obj/effect/landmark,
))

// Per-type extra vars, by typepath. A mineral door's open/closed and
// locked state live in its own vars, not in density, so they are
// saved explicitly. More types gain entries here as they need them.
/proc/persistence_world_type_vars(obj/O)
	if(istype(O, /obj/structure/mineral_door))
		return list("door_opened", "locked")
	return null

// The loaded world's name, sanitised for a folder name (lowercase
// a-z0-9, like the character-save sanitiser). Falls back to the map
// config name, then to "world".
/proc/persistence_world_name()
	var/name = SSmapping?.config?.map_name || config?.map_name || "world"
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
/proc/persistence_world_map_zs()
	var/start = SSmapping?.station_start || 1
	var/end = world.maxz
	var/transit_z = SSmapping?.transit?.z_value
	if(transit_z && transit_z <= end)
		end = transit_z - 1
	var/list/zs = list()
	for(var/z in start to end)
		zs += z
	return zs

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
		// Turfs: a full sweep of the z-level. Each entry is a
		// positional list (x, y, type).
		var/turf/corner_a = locate(1, 1, z)
		var/turf/corner_b = locate(world.maxx, world.maxy, z)
		for(var/turf/T in block(corner_a, corner_b))
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
	var/list/generations = persistence_world_generations()
	if(!length(generations))
		return FALSE
	for(var/generation in generations)
		var/dir = "[persistence_world_map_dir()][generation]/"
		if(!fexists("[dir]complete"))
			log_world("Persistence: world save generation [generation] has no completion marker — incomplete, trying the previous generation.")
			continue
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
	// Read and validate every z-level before touching the world.
	var/list/z_data = list()
	for(var/z in zs)
		var/list/data = persistence_world_read_z(dir, z)
		if(!data)
			return FALSE
		z_data["[z]"] = data
	// All valid. Remove the in-scope atoms first, so the saved atoms
	// are not duplicated on top of the fresh map's. Landmarks and
	// mapping helpers are left alone (they self-delete after loading);
	// loot spawners are removed with the rest, so they do not fire
	// again on top of the saved loot.
	persistence_world_clear_atoms()
	// Suppress container population while the atoms are rebuilt, so a
	// restored container does not fill itself with its defaults on
	// top of its saved contents. The per-item flag (set on each
	// restored container) is the reliable guard, since PopulateContents
	// is deferred a tick; this global flag covers any call that runs
	// synchronously.
	GLOB.persistence_suppress_populate = TRUE
	for(var/z in zs)
		persistence_world_restore_z(z_data["[z]"], z)
	GLOB.persistence_suppress_populate = FALSE
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
// Landmarks and mapping helpers are left alone; loot spawners are
// removed with the rest, so they do not fire again on top of the
// saved loot. Contents are removed first, so nothing is orphaned.
// Atoms are collected first and deleted after, so deleting does not
// disturb the iteration.
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
		to_delete += O
	for(var/obj/O in to_delete)
		persistence_world_delete_atom(O)

// Recursively delete an atom and its contents.
/proc/persistence_world_delete_atom(obj/O)
	var/list/kids = O.contents.Copy()
	for(var/obj/K in kids)
		persistence_world_delete_atom(K)
	qdel(O)

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
	var/list/kids = entry[5]
	if(length(kids))
		for(var/list/kid in kids)
			var/obj/child = persistence_world_restore_atom(kid, z)
			if(child)
				child.forceMove(O)
	return O
