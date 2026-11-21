// Prototype 1: character saves.
//
// A versioned save of one character, keyed by CHARACTER NAME (not by slot).
// One folder per character inside the player's save folder:
//
//   data/player_saves/[first letter]/[ckey]/[sanitized-name]/[sanitized-name].sav
//   data/player_saves/[first letter]/[ckey]/[sanitized-name]/backup
//
// The file name is the character's name, lowercased, with no spaces,
// punctuation, or special characters. The backup file is the previous
// generation of the live save, copied aside before a new save overwrites it.
// The character's preferences-slot number is stored in the save as a link
// (the slot still defines flavour text, OOC notes, and similar text
// preferences once a save exists) — it is NOT the file key.
//
// What this is: the character half of persistence. Saves happen when a living
// character uses Far Travel (see the hook in fartravel.dm), when the server
// prepares to restart (not wired in yet), and when an admin runs the
// "Test World Save" verb (see persistence_verbs.dm).
//
// What this is NOT: the world save (Prototype 2), the treasury sweep, loans,
// bounties, seasons, or the 24-hour timer. None of those are in this file.
//
// Deliberately not saved in version 1: transient runtime state, antagonist
// (villain) roles and special roles (round-scoped), starting gear and
// roundstart stash replenishment (the job equip step never runs on load),
// per-item state such as durability, quality, and reagents (version 2;
// coin amounts, dye-station colours, and grid positions ARE saved, see save_item), and status effects (the whitelist below is empty in version 1
// — every status effect checked is a short timer, or is derived from the
// saved hunger/thirst stages, whose debuffs re-derive on life ticks).
//
// A failed save is logged in the admin log, and — once the character is
// identified — in save_errors.log inside that character's save folder, so
// the failure sits next to the save it belongs to.
//
// The load path (apply_to) is wired into the live spawn path: latejoin
// (AttemptLateSpawn) and roundstart (equip_characters), both asking the
// player first. It is built parallel to copy_to(): appearance and species
// come from the save, stats and skills are applied as saved final values
// (no re-roll), and job equip is never run.
//
// This code has not been compiled: BYOND cannot run on this machine.
// Compile it locally with tools/build/build.bat (BYOND 516.1687, the version
// the repo pins) before trusting any of it.

#define CHARACTER_SAVE_VERSION_MIN 1
#define CHARACTER_SAVE_VERSION_MAX 1

// While a character load is restoring inventory, containers must NOT fill
// themselves with their default contents: /obj/item/storage populates a
// tick after Initialize() (spawn(0) PopulateContents()), so the defaults
// would land on top of the restored saved contents. Set TRUE while a load
// is rebuilding inventory, cleared a tick later, after every PopulateContents
// scheduled during the load has had its chance to check it.
GLOBAL_VAR_INIT(persistence_suppress_populate, FALSE)

// The primary treasury ID lives on the human so the save can read it. The
// treasury itself does not exist yet; the field stays empty until it does.
// Declared here, in the persistence module, so no existing file is touched.
/mob/living/carbon/human/var/primary_treasury_id = ""

/datum/character_save
	// Wear slots checked when figuring out where a worn item sits. Handcuffed
	// and legcuffed are left out on purpose: restraints are transient, not
	// inventory. SLOT_HANDS is handled separately (held items).
	var/static/list/character_save_wear_slots = list(
		SLOT_BACK, SLOT_BACK_L, SLOT_BACK_R,
		SLOT_BELT, SLOT_BELT_L, SLOT_BELT_R,
		SLOT_CLOAK, SLOT_HEAD, SLOT_MOUTH, SLOT_WEAR_MASK, SLOT_NECK,
		SLOT_GLOVES, SLOT_RING, SLOT_WRISTS,
		SLOT_ARMOR, SLOT_SHIRT, SLOT_SHOES, SLOT_PANTS,
		SLOT_GLASSES, SLOT_L_STORE, SLOT_R_STORE, SLOT_S_STORE,
	)

	// Status effects that may be carried across rounds. Empty in version 1:
	// every status effect found in the code is a short timer, or is derived
	// from saved state (hunger/thirst stages). Add entries here only for
	// effects that are durable character state, and bump the save version
	// when doing so.
	var/list/character_save_status_whitelist = list()

	// Trait sources that belong to the character, not to a passing moment.
	// Only traits carrying one of these sources are saved; a trait from a
	// spell, a drink, a status effect, or worn gear is left out, since the
	// load re-derives those or they should not persist. TRAIT_GENERIC is
	// deliberately not here — it is the catch-all, used for passing grants
	// as well as lasting ones. ADVENTURER_TRAIT is in: it is used only for
	// a class's traits_applied grant in advclass equipme, so it is lasting
	// character state, not a passing grant.
	var/static/list/character_save_trait_sources = list(
		JOB_TRAIT, TRAIT_VIRTUE, SPECIES_TRAIT, ROUNDSTART_TRAIT, TRAIT_CURSE,
		ADVENTURER_TRAIT,
	)

	var/ckey
	var/slot = 1 // Preferences-slot link only. Not the file key.
	var/real_name
	// Species and DNA.
	var/species_type
	var/list/dna_features = list()
	var/list/dna_body_markings = list()
	var/blood_type
	var/unique_enzymes
	var/uni_identity
	var/list/organ_dna = list()
	var/current_body_size
	// Appearance scalars.
	var/age
	var/gender
	var/nickname
	var/pronouns
	var/voice_color
	var/voice_pitch
	var/voice_type
	var/skin_tone
	var/domhand
	// Stats, saved as final values. No re-roll on load.
	var/list/stats = list()
	// Build choices. Virtues live on the preferences datum only (the slot
	// owns them), so they are not saved here.
	var/statpack_type
	var/list/charflaw_types = list()
	// Skills: typepath -> level, typepath -> experience.
	var/list/skill_levels = list()
	var/list/skill_xp = list()
	// Job. The job datum itself is re-resolved by title on load.
	var/job_title
	var/advjob
	var/advclass_type
	// Traits: trait name -> list of sources, as the mob had them, lasting
	// sources only (see character_save_trait_sources above).
	var/list/traits = list()
	// Inventory: recursive entries of list("type", "slot", "contents").
	// Slot is a SLOT_* number for worn items, SLOT_HANDS for held items,
	// 0 for items inside another item (or with no slot).
	var/list/inventory = list()
	// Health: one entry per bodypart present, list("zone", "brute", "burn",
	// "stamina", "disabled", "wounds" = list of wound typepaths). Bodyparts
	// missing from this list were missing from the character.
	var/list/bodyparts = list()
	// Organs: typepaths of organs present.
	var/list/organs = list()
	var/hunger_stage
	var/thirst_stage
	var/blood_volume
	// Status effects, whitelisted only (empty in version 1).
	var/list/status_effects = list()
	// Magic and religion: typepaths.
	var/list/spell_types = list()
	var/list/major_aspect_types = list()
	var/list/minor_aspect_types = list()
	var/patron_type
	var/devotion_type // Saved for later; restore is deferred (see apply_to).
	// Relationships, name-keyed so they stand alone.
	var/list/known_people = list()
	var/fellowship_name
	// Location and anchor. The anchor (bed/home) fields are 0 until the
	// anchor system lands; until then placement falls back to loc_*.
	var/loc_x
	var/loc_y
	var/loc_z
	var/loc_area_type
	var/home_x = 0
	var/home_y = 0
	var/home_z = 0
	var/home_area_type
	// Treasury. Plain text, never a reference.
	var/primary_treasury_id = ""
	// Why the last save failed, for the logs. Empty when the last save worked.
	var/save_error = ""

// The file name for a character: lowercase, letters and digits only.
// Falls back to "character" if nothing survives the filter.
/datum/character_save/proc/character_save_filename(character_name)
	var/clean = lowertext(character_name)
	var/allowed = "abcdefghijklmnopqrstuvwxyz0123456789"
	var/out = ""
	for(var/i = 1, i <= length(clean), i++)
		var/ch = copytext(clean, i, i + 1)
		if(findtext(allowed, ch))
			out += ch
	if(!length(out))
		out = "character"
	return copytext(out, 1, 65)

// One folder per character inside the player's save folder.
/datum/character_save/proc/save_path(save_ckey, character_name)
	var/folder = character_save_filename(character_name)
	return "data/player_saves/[copytext(save_ckey, 1, 2)]/[save_ckey]/[folder]/[folder].sav"

// The backup lives in the same folder as the live save, named "backup".
/datum/character_save/proc/backup_path(save_ckey, character_name)
	var/folder = character_save_filename(character_name)
	return "data/player_saves/[copytext(save_ckey, 1, 2)]/[save_ckey]/[folder]/backup"

/datum/character_save/proc/character_save_exists(save_ckey, character_name)
	if(!save_ckey || !character_name)
		return FALSE
	return fexists(save_path(save_ckey, character_name))

// Record a failed save in the character's own save folder, so the failure
// is visible next to the save it belongs to (and not only in the admin
// log). Only possible once the ckey and name are known — a failure before
// that has no folder to write to, and stays admin-log only. The reason is
// kept on the datum too, so callers can include it in the admin log.
/datum/character_save/proc/note_save_error(reason)
	save_error = reason
	if(!ckey || !real_name)
		return
	var/folder = character_save_filename(real_name)
	var/log_path = "data/player_saves/[copytext(ckey, 1, 2)]/[ckey]/[folder]/save_errors.log"
	var/stamp = time2text(world.realtime, "YYYY-MM-DD hh:mm:ss")
	text2file("[stamp] Save failed: [reason]\n", log_path)

// Save a character as they are, living or dead. The dead-refusal belongs to
// the Far Travel hook, not here: the restart and test-verb saves need dead
// characters saved exactly as they are, where they are.
/datum/character_save/proc/save_character(mob/living/carbon/human/H)
	if(!H || !H.real_name)
		save_error = "no character or no name"
		return FALSE
	var/save_ckey = H.ckey
	if(!save_ckey && H.mind?.key)
		save_ckey = ckey(H.mind.key)
	if(!save_ckey)
		save_error = "no ckey"
		return FALSE

	// Identity.
	src.ckey = save_ckey
	src.slot = H.client?.prefs?.default_slot || 1
	real_name = H.real_name

	// Species and DNA.
	if(H.dna)
		species_type = H.dna.species?.type
		dna_features = H.dna.features.Copy()
		dna_body_markings = deepCopyList(H.dna.body_markings)
		blood_type = H.dna.blood_type
		unique_enzymes = H.dna.unique_enzymes
		uni_identity = H.dna.uni_identity
		organ_dna = H.dna.organ_dna.Copy()
		current_body_size = H.dna.current_body_size

	// Appearance scalars.
	age = H.age
	gender = H.gender
	nickname = H.nickname
	pronouns = H.pronouns
	voice_color = H.voice_color
	voice_pitch = H.voice_pitch
	voice_type = H.voice_type
	skin_tone = H.skin_tone
	domhand = H.domhand

	// Stats, final values.
	stats = list(
		"STASTR" = H.STASTR, "STAPER" = H.STAPER, "STAINT" = H.STAINT,
		"STACON" = H.STACON, "STAWIL" = H.STAWIL, "STASPD" = H.STASPD,
		"STALUC" = H.STALUC,
	)

	// Build choices.
	statpack_type = H.statpack?.type
	charflaw_types = list()
	for(var/datum/charflaw/CF in H.charflaws)
		charflaw_types += CF.type

	// Skills.
	var/datum/skill_holder/SH = H.ensure_skills()
	if(SH)
		skill_levels = SH.known_skills.Copy()
		skill_xp = SH.skill_experience.Copy()

	// Job.
	job_title = H.job
	advjob = H.advjob
	advclass_type = H.mind?.picked_advclass?.type

	// Traits, lasting sources only. The map is copied, not aliased: the
	// mob's live list must not be reachable from the save datum.
	traits = list()
	if(H.status_traits)
		for(var/trait in H.status_traits)
			var/list/kept_sources = list()
			for(var/source in H.status_traits[trait])
				if(istext(source) && (source in character_save_trait_sources))
					kept_sources += source
			if(length(kept_sources))
				traits[trait] = kept_sources

	// Inventory, recursive. Bodyparts and organs are body, not inventory,
	// and restraints are transient — none of them are saved as items.
	inventory = list()
	for(var/obj/item/I in H.contents)
		if(istype(I, /obj/item/bodypart) || istype(I, /obj/item/organ))
			continue
		if(I == H.handcuffed || I == H.legcuffed)
			continue
		inventory += list(save_item(H, I))

	// Health: bodyparts present, with damage and wounds.
	bodyparts = list()
	for(var/obj/item/bodypart/BP in H.bodyparts)
		var/list/wound_types = list()
		if(BP.wounds)
			for(var/datum/wound/W in BP.wounds)
				wound_types += W.type
		bodyparts += list(list(
			"zone" = BP.body_zone,
			"brute" = BP.brute_dam,
			"burn" = BP.burn_dam,
			"stamina" = BP.stamina_dam,
			"disabled" = BP.disabled,
			"wounds" = wound_types,
		))

	// Organs present.
	organs = list()
	for(var/obj/item/organ/O in H.internal_organs)
		organs += O.type

	// Hunger, thirst, blood.
	hunger_stage = H.hunger_stage
	thirst_stage = H.thirst_stage
	blood_volume = H.blood_volume

	// Status effects, whitelisted only.
	status_effects = list()
	for(var/datum/status_effect/SE in H.status_effects)
		if(SE.type in character_save_status_whitelist)
			status_effects += SE.type

	// Magic and religion.
	spell_types = list()
	major_aspect_types = list()
	minor_aspect_types = list()
	if(H.mind)
		// Spells are /obj/effect/proc_holder/spell objects, not /datum/spell,
		// so the loop var is typed to the real type.
		for(var/obj/effect/proc_holder/spell/S in H.mind.spell_list)
			spell_types += S.type
		for(var/datum/magic_aspect/A in H.mind.major_aspects)
			major_aspect_types += A.type
		for(var/datum/magic_aspect/A in H.mind.minor_aspects)
			minor_aspect_types += A.type
	if(ispath(H.patron))
		patron_type = H.patron
	else if(H.patron)
		patron_type = H.patron.type
	devotion_type = H.devotion?.type

	// Relationships, name-keyed.
	if(H.mind)
		known_people = H.mind.known_people.Copy()
	fellowship_name = H.current_fellowship?.name

	// Location and anchor.
	loc_x = H.x
	loc_y = H.y
	loc_z = H.z
	var/area/A = get_area(H)
	loc_area_type = A?.type
	// home_* stay 0 until the anchor system (bed claims) lands.

	// Treasury.
	primary_treasury_id = H.primary_treasury_id || ""

	// Rotate the backup first, so a failed write never destroys the last
	// good save. Then write the live save.
	var/path = save_path(save_ckey, real_name)
	if(fexists(path))
		fcopy(path, backup_path(save_ckey, real_name))
	var/savefile/S = new /savefile(path)
	if(!S)
		note_save_error("could not open savefile at [path]")
		return FALSE
	S.cd = "/"
	WRITE_FILE(S["version"], CHARACTER_SAVE_VERSION_MAX)
	WRITE_FILE(S["ckey"], ckey)
	WRITE_FILE(S["slot"], slot)
	WRITE_FILE(S["real_name"], real_name)
	WRITE_FILE(S["species_type"], species_type)
	WRITE_FILE(S["dna_features"], dna_features)
	WRITE_FILE(S["dna_body_markings"], dna_body_markings)
	WRITE_FILE(S["blood_type"], blood_type)
	WRITE_FILE(S["unique_enzymes"], unique_enzymes)
	WRITE_FILE(S["uni_identity"], uni_identity)
	WRITE_FILE(S["organ_dna"], organ_dna)
	WRITE_FILE(S["current_body_size"], current_body_size)
	WRITE_FILE(S["age"], age)
	WRITE_FILE(S["gender"], gender)
	WRITE_FILE(S["nickname"], nickname)
	WRITE_FILE(S["pronouns"], pronouns)
	WRITE_FILE(S["voice_color"], voice_color)
	WRITE_FILE(S["voice_pitch"], voice_pitch)
	WRITE_FILE(S["voice_type"], voice_type)
	WRITE_FILE(S["skin_tone"], skin_tone)
	WRITE_FILE(S["domhand"], domhand)
	WRITE_FILE(S["stats"], stats)
	WRITE_FILE(S["statpack_type"], statpack_type)
	WRITE_FILE(S["charflaw_types"], charflaw_types)
	WRITE_FILE(S["skill_levels"], skill_levels)
	WRITE_FILE(S["skill_xp"], skill_xp)
	WRITE_FILE(S["job_title"], job_title)
	WRITE_FILE(S["advjob"], advjob)
	WRITE_FILE(S["advclass_type"], advclass_type)
	WRITE_FILE(S["traits"], traits)
	WRITE_FILE(S["inventory"], inventory)
	WRITE_FILE(S["bodyparts"], bodyparts)
	WRITE_FILE(S["organs"], organs)
	WRITE_FILE(S["hunger_stage"], hunger_stage)
	WRITE_FILE(S["thirst_stage"], thirst_stage)
	WRITE_FILE(S["blood_volume"], blood_volume)
	WRITE_FILE(S["status_effects"], status_effects)
	WRITE_FILE(S["spell_types"], spell_types)
	WRITE_FILE(S["major_aspect_types"], major_aspect_types)
	WRITE_FILE(S["minor_aspect_types"], minor_aspect_types)
	WRITE_FILE(S["patron_type"], patron_type)
	WRITE_FILE(S["devotion_type"], devotion_type)
	WRITE_FILE(S["known_people"], known_people)
	WRITE_FILE(S["fellowship_name"], fellowship_name)
	WRITE_FILE(S["loc_x"], loc_x)
	WRITE_FILE(S["loc_y"], loc_y)
	WRITE_FILE(S["loc_z"], loc_z)
	WRITE_FILE(S["loc_area_type"], loc_area_type)
	WRITE_FILE(S["home_x"], home_x)
	WRITE_FILE(S["home_y"], home_y)
	WRITE_FILE(S["home_z"], home_z)
	WRITE_FILE(S["home_area_type"], home_area_type)
	WRITE_FILE(S["primary_treasury_id"], primary_treasury_id)
	return TRUE

// One item, recursively. Typepath + slot + contents, plus coin quantity
// for coin piles (a pile's amount is money, and money must survive the
// load). Other per-item state (durability, quality, reagents) is version 2.
/datum/character_save/proc/save_item(mob/living/carbon/human/H, obj/item/I, atom/parent_storage = null)
	var/list/entry = list()
	entry["type"] = I.type
	entry["slot"] = get_item_slot(H, I)
	if(istype(I, /obj/item/roguecoin))
		var/obj/item/roguecoin/C = I
		entry["quantity"] = C.quantity
	// Grid position. A grid container records each item's origin cell
	// (and its footprint, which a flip can swap) in its storage
	// component; without it every restored item renders at the first
	// cell (0,0). Only recorded when the parent is a grid container
	// and the item has a recorded cell, so items on the mob or in a
	// plain container carry no grid fields at all.
	if(istype(parent_storage, /obj/item/storage))
		var/datum/component/storage/STR = parent_storage.GetComponent(/datum/component/storage)
		if(STR && STR.grid)
			var/list/coords = STR.first_coordinates_item[I]
			if(coords && coords.len >= 2)
				entry["grid_x"] = coords[1]
				entry["grid_y"] = coords[2]
				entry["grid_width"] = I.grid_width
				entry["grid_height"] = I.grid_height
	// Dye-station colours. The primary dye lives in the atom-colour list
	// at the FIXED priority — temporary tints (a cold debuff, a spell
	// effect) use other priorities and are deliberately not saved — and
	// the detail colours are plain vars on the item. Only non-null
	// colours are recorded, so an undyed item carries no colour fields
	// at all, and old saves simply omit them.
	if(I.atom_colours && I.atom_colours.len >= FIXED_COLOUR_PRIORITY)
		var/dye = I.atom_colours[FIXED_COLOUR_PRIORITY]
		if(dye)
			entry["dye_color"] = dye
	if(I.detail_color)
		entry["detail_color"] = I.detail_color
	if(I.altdetail_color)
		entry["altdetail_color"] = I.altdetail_color
	var/list/kids = list()
	for(var/obj/item/K in I.contents)
		kids += list(save_item(H, K, I))
	entry["contents"] = kids
	return entry

// Where an item sits: a SLOT_* number if worn, SLOT_HANDS if held,
// 0 if it is inside another item or has no slot (dropped at the
// character's feet on load).
/datum/character_save/proc/get_item_slot(mob/living/carbon/human/H, obj/item/I)
	if(I in H.held_items)
		return SLOT_HANDS
	for(var/slot in character_save_wear_slots)
		if(H.get_item_by_slot(slot) == I)
			return slot
	return 0

// Load a save file into this datum. Returns FALSE if there is no save,
// or if the version is outside what this code understands.
/datum/character_save/proc/load_character(load_ckey, character_name)
	if(!load_ckey || !character_name)
		return FALSE
	var/path = save_path(load_ckey, character_name)
	if(!fexists(path))
		return FALSE
	var/savefile/S = new /savefile(path)
	if(!S)
		return FALSE
	S.cd = "/"
	var/savefile_version
	S["version"] >> savefile_version
	if(!savefile_version || savefile_version < CHARACTER_SAVE_VERSION_MIN || savefile_version > CHARACTER_SAVE_VERSION_MAX)
		return FALSE
	S["ckey"] >> ckey
	S["slot"] >> slot
	S["real_name"] >> real_name
	S["species_type"] >> species_type
	S["dna_features"] >> dna_features
	S["dna_body_markings"] >> dna_body_markings
	S["blood_type"] >> blood_type
	S["unique_enzymes"] >> unique_enzymes
	S["uni_identity"] >> uni_identity
	S["organ_dna"] >> organ_dna
	S["current_body_size"] >> current_body_size
	S["age"] >> age
	S["gender"] >> gender
	S["nickname"] >> nickname
	S["pronouns"] >> pronouns
	S["voice_color"] >> voice_color
	S["voice_pitch"] >> voice_pitch
	S["voice_type"] >> voice_type
	S["skin_tone"] >> skin_tone
	S["domhand"] >> domhand
	S["stats"] >> stats
	S["statpack_type"] >> statpack_type
	S["charflaw_types"] >> charflaw_types
	S["skill_levels"] >> skill_levels
	S["skill_xp"] >> skill_xp
	S["job_title"] >> job_title
	S["advjob"] >> advjob
	S["advclass_type"] >> advclass_type
	S["traits"] >> traits
	S["inventory"] >> inventory
	S["bodyparts"] >> bodyparts
	S["organs"] >> organs
	S["hunger_stage"] >> hunger_stage
	S["thirst_stage"] >> thirst_stage
	S["blood_volume"] >> blood_volume
	S["status_effects"] >> status_effects
	S["spell_types"] >> spell_types
	S["major_aspect_types"] >> major_aspect_types
	S["minor_aspect_types"] >> minor_aspect_types
	S["patron_type"] >> patron_type
	S["devotion_type"] >> devotion_type
	S["known_people"] >> known_people
	S["fellowship_name"] >> fellowship_name
	S["loc_x"] >> loc_x
	S["loc_y"] >> loc_y
	S["loc_z"] >> loc_z
	S["loc_area_type"] >> loc_area_type
	S["home_x"] >> home_x
	S["home_y"] >> home_y
	S["home_z"] >> home_z
	S["home_area_type"] >> home_area_type
	S["primary_treasury_id"] >> primary_treasury_id
	return TRUE

// Apply a loaded save to a freshly built human. Parallel to copy_to():
// appearance and species come from the save, stats and skills are applied
// as saved final values (no re-roll), and job equip is NEVER run here.
// The human must already exist (built by the spawn path) but must not have
// been equipped or stat-rolled yet. NOT wired into the live spawn path yet.
// Returns FALSE if there is nothing to apply.
/datum/character_save/proc/apply_to(mob/living/carbon/human/H)
	if(!H || !real_name)
		return FALSE

	// Identity and appearance scalars.
	H.real_name = real_name
	H.name = real_name
	H.age = age
	H.gender = gender
	H.nickname = nickname
	H.pronouns = pronouns
	H.voice_color = voice_color
	H.voice_pitch = voice_pitch
	H.voice_type = voice_type
	H.skin_tone = skin_tone
	H.domhand = domhand

	// Flaws first, as in copy_to() (a flaw can change the body).
	H.charflaws.Cut()
	for(var/cf_type in charflaw_types)
		if(ispath(cf_type, /datum/charflaw))
			H.charflaws += new cf_type()

	// Species and DNA, following the transfer_identity() order: species
	// first (it can reset features), then the saved DNA over the top.
	if(species_type && ispath(species_type, /datum/species))
		H.set_species(species_type, icon_update = FALSE)
	if(H.dna)
		if(length(dna_features))
			H.dna.features = dna_features.Copy()
		if(length(dna_body_markings))
			H.dna.body_markings = deepCopyList(dna_body_markings)
		if(blood_type)
			H.dna.blood_type = blood_type
		if(unique_enzymes)
			H.dna.unique_enzymes = unique_enzymes
		if(uni_identity)
			H.dna.uni_identity = uni_identity
		if(length(organ_dna))
			H.dna.organ_dna = organ_dna.Copy()
		if(current_body_size)
			H.dna.current_body_size = current_body_size
		H.dna.real_name = real_name
		H.regenerate_organs()
		H.dna.update_body_size()

	// Stats, as saved. No re-roll, no statpack re-application: the saved
	// values already include everything that shaped them.
	if(length(stats))
		H.STASTR = stats["STASTR"] || 10
		H.STAPER = stats["STAPER"] || 10
		H.STAINT = stats["STAINT"] || 10
		H.STACON = stats["STACON"] || 10
		H.STAWIL = stats["STAWIL"] || 10
		H.STASPD = stats["STASPD"] || 10
		H.STALUC = stats["STALUC"] || 10

	// Statpack is recorded, not re-applied: its contribution is already in
	// the saved stats, and re-applying it would count it twice.
	if(statpack_type && ispath(statpack_type, /datum/statpack))
		H.statpack = new statpack_type

	// Skills.
	var/datum/skill_holder/SH = H.ensure_skills()
	if(SH)
		if(length(skill_levels))
			SH.known_skills = skill_levels.Copy()
		if(length(skill_xp))
			SH.skill_experience = skill_xp.Copy()

	// Job. The job datum is re-resolved by title; equip is never run.
	if(job_title)
		H.job = job_title
		if(H.mind)
			var/datum/job/J = SSjob.GetJob(job_title)
			if(J)
				H.mind.set_assigned_role(J)
	if(advjob)
		H.advjob = advjob
	if(advclass_type && ispath(advclass_type, /datum/advclass) && H.mind)
		H.mind.picked_advclass = new advclass_type

	// Traits, authoritatively: the saved set is what the character had,
	// so it wins over anything the fresh human gained from the slot. First
	// drop any lasting-sourced trait the fresh human has that the save
	// does not list (a virtue changed in the slot since the save, for
	// instance); then add every saved trait with its saved sources.
	// Passing-sourced traits are left alone — the load re-derives those
	// or they should not persist. Old saves have no traits field, so this
	// whole block is skipped for them.
	if(length(traits))
		if(H.status_traits)
			for(var/trait in H.status_traits.Copy())
				if(traits[trait])
					continue
				var/list/sources = H.status_traits[trait]
				var/all_lasting = TRUE
				for(var/source in sources)
					if(!istext(source) || !(source in character_save_trait_sources))
						all_lasting = FALSE
						break
				if(all_lasting)
					REMOVE_TRAIT(H, trait, null)
					REMOVE_TRAIT(H, trait, ROUNDSTART_TRAIT)
		for(var/trait in traits)
			for(var/source in traits[trait])
				ADD_TRAIT(H, trait, source)

	// Health: drop limbs the save does not have, then restore damage
	// and wounds on the limbs it does have.
	var/list/saved_zones = list()
	for(var/list/bp_entry in bodyparts)
		saved_zones += bp_entry["zone"]
	for(var/obj/item/bodypart/BP in H.bodyparts.Copy())
		if(!(BP.body_zone in saved_zones))
			BP.drop_limb()
	for(var/list/bp_entry in bodyparts)
		var/obj/item/bodypart/BP = H.get_bodypart(bp_entry["zone"])
		if(!BP)
			continue
		BP.brute_dam = bp_entry["brute"]
		BP.burn_dam = bp_entry["burn"]
		BP.stamina_dam = bp_entry["stamina"]
		BP.disabled = bp_entry["disabled"]
		for(var/wound_type in bp_entry["wounds"])
			if(ispath(wound_type, /datum/wound))
				BP.add_wound(wound_type)

	// Organs: remove what the save does not have, add what it has.
	for(var/obj/item/organ/O in H.internal_organs.Copy())
		if(!(O.type in organs))
			O.Remove(H)
			qdel(O)
	for(var/organ_type in organs)
		var/found = FALSE
		for(var/obj/item/organ/O in H.internal_organs)
			if(O.type == organ_type)
				found = TRUE
				break
		if(!found && ispath(organ_type, /obj/item/organ))
			var/obj/item/organ/new_organ = new organ_type
			new_organ.Insert(H)

	// Hunger, thirst, blood. The hunger/thirst debuffs re-derive from
	// these stages on life ticks.
	if(!isnull(hunger_stage))
		H.hunger_stage = hunger_stage
	if(!isnull(thirst_stage))
		H.thirst_stage = thirst_stage
	if(!isnull(blood_volume))
		H.blood_volume = blood_volume

	// Inventory, rebuilt from typepaths. Nothing here runs the job equip.
	// Containers are restored exactly as saved: the flag below stops
	// storage items from re-adding their default contents a tick later,
	// and restore_inventory empties anything Initialize() already put in.
	GLOB.persistence_suppress_populate = TRUE
	restore_inventory(H, inventory, null)
	spawn(1)
		GLOB.persistence_suppress_populate = FALSE

	// Magic and religion. Spells first: aspect attunement auto-resolves
	// its choice spell from the spells the character already has.
	if(H.mind)
		for(var/spell_type in spell_types)
			if(!ispath(spell_type))
				continue
			var/datum/new_spell = new spell_type
			H.mind.AddSpell(new_spell, H)
		for(var/aspect_type in major_aspect_types)
			if(!ispath(aspect_type, /datum/magic_aspect))
				continue
			var/datum/magic_aspect/A = new aspect_type
			H.mind.attune_aspect(A)
		for(var/aspect_type in minor_aspect_types)
			if(!ispath(aspect_type, /datum/magic_aspect))
				continue
			var/datum/magic_aspect/A = new aspect_type
			H.mind.attune_aspect(A)
		if(length(known_people))
			H.mind.known_people = known_people.Copy()
	if(patron_type)
		H.set_patron(patron_type)
	// Devotion is saved but not restored in version 1: the devotion datum
	// is wired to its cleric holder, and that wiring has not been verified
	// for a load path yet. Revisit when the religion save lands.
	H.primary_treasury_id = primary_treasury_id || ""

	// Fellowship, re-resolved by name.
	if(fellowship_name)
		for(var/datum/fellowship/F in GLOB.fellowships)
			if(F.name == fellowship_name)
				F.add_member(H)
				break

	// Placement: the saved location. The anchor system (active bedroll >
	// static home > nearest safezone) replaces this once it lands; until
	// then the character wakes where they were saved.
	if(loc_x && loc_y && loc_z)
		var/turf/T = locate(loc_x, loc_y, loc_z)
		if(T)
			H.forceMove(T)

	// Status effects: none in version 1 (whitelist is empty). Whitelisted
	// effects are re-applied here when the whitelist gains entries.

	H.update_body()
	H.update_hair()
	H.update_body_parts()
	return TRUE

// Rebuild the saved inventory tree. Top-level items go to their saved slot
// (worn, held, or dropped at the character's feet if the slot cannot take
// them); nested items go inside their saved parent container.
/datum/character_save/proc/restore_inventory(mob/living/carbon/human/H, list/entries, atom/parent)
	for(var/list/entry in entries)
		var/item_type = entry["type"]
		if(!ispath(item_type, /obj/item))
			continue
		// Coin piles carry their amount: the coin type takes it as a
		// second Initialize argument, so a restored pile is worth what
		// was saved. Saves made before this field existed simply omit
		// it, and the pile comes back as a single coin.
		var/obj/item/I
		if(ispath(item_type, /obj/item/roguecoin) && entry["quantity"])
			I = new item_type(H.loc, entry["quantity"])
		else
			I = new item_type(H.loc)
		// Persistence: mark a restored container so its deferred
		// PopulateContents() stays off even if the global suppress flag
		// clears before the spawn(0) callback runs. The coin-pouch
		// subtypes populate through that deferred call, and their
		// default piles were landing on top of the saved coins.
		if(istype(I, /obj/item/storage))
			var/obj/item/storage/S = I
			S.persistence_no_defaults = TRUE
		// A container can fill itself in Initialize() — a pre-packed box,
		// a stocked pouch — and the save already records the exact
		// contents it had, so anything already inside a freshly created
		// item is a default that must go before the saved contents are
		// restored. (Storage items populate a tick later instead; the
		// suppress flag above stops that half.)
		for(var/obj/item/C in I.contents.Copy())
			qdel(C)
		if(parent)
			I.forceMove(parent)
			// Grid position, as saved (or the first free cell when the
			// save has none, or the saved cell is taken): a restored
			// item has no grid coordinate of its own, so without this
			// every item in a grid container renders at the first cell.
			restore_grid_coordinate(I, parent, entry)
		else
			var/slot = entry["slot"]
			if(slot == SLOT_HANDS)
				if(!H.put_in_hands(I))
					I.forceMove(H.loc)
			else if(slot && (slot in character_save_wear_slots))
				if(!H.equip_to_slot_if_possible(I, slot, FALSE, TRUE, FALSE, TRUE))
					I.forceMove(H.loc)
			else
				I.forceMove(H.loc)
		var/list/kids = entry["contents"]
		if(length(kids))
			restore_inventory(H, kids, I)
		// Dye-station colours, as saved: the primary dye goes back
		// through add_atom_colour at the FIXED priority, exactly as the
		// dye station applied it, and the detail colours are plain vars.
		// Saves made before these fields existed omit them, and the item
		// keeps whatever colour it was created with. The icon is rebuilt
		// only for dyed items, after the contents are restored, so the
		// detail overlays use the saved colours.
		var/dyed = FALSE
		if(entry["dye_color"])
			I.add_atom_colour(entry["dye_color"], FIXED_COLOUR_PRIORITY)
			dyed = TRUE
		if(entry["detail_color"])
			I.detail_color = entry["detail_color"]
			dyed = TRUE
		if(entry["altdetail_color"])
			I.altdetail_color = entry["altdetail_color"]
			dyed = TRUE
		if(dyed)
			I.update_icon()

// Put a restored item on its saved grid cell, or the first free cell.
// The coordinate lives in the container's storage component, not on
// the item, so it is recorded per item at save time and re-applied
// here; a flip is kept by restoring the saved footprint first, so the
// saved cell validates against the size the item had. Old saves omit
// the grid fields, so their items simply take the first free cell.
/datum/character_save/proc/restore_grid_coordinate(obj/item/I, atom/parent, list/entry)
	if(!istype(parent, /obj/item/storage))
		return
	var/datum/component/storage/STR = parent.GetComponent(/datum/component/storage)
	if(!STR || !STR.grid)
		return
	if(entry["grid_width"])
		I.grid_width = entry["grid_width"]
	if(entry["grid_height"])
		I.grid_height = entry["grid_height"]
	var/grid_x = entry["grid_x"]
	var/grid_y = entry["grid_y"]
	var/coordinates
	if(!isnull(grid_x) && !isnull(grid_y) && STR.validate_grid_coordinates("[grid_x],[grid_y]", I.grid_width, I.grid_height, I))
		coordinates = "[grid_x],[grid_y]"
	else
		coordinates = first_free_grid_coordinate(STR, I)
	if(coordinates)
		STR.grid_add_item(I, coordinates)

// First free grid cell for an item, scanning the way the normal insert
// path does (row by row from the first cell). Returns null when the
// grid is genuinely full.
/datum/character_save/proc/first_free_grid_coordinate(datum/component/storage/STR, obj/item/I)
	var/grid_box_ratio = (world.icon_size / STR.grid_box_size)
	var/x_value = ((STR.screen_max_columns * grid_box_ratio) - 1)
	for(var/current_y in 0 to ((STR.screen_max_rows * grid_box_ratio) - 1))
		for(var/current_x in 0 to x_value)
			var/final_coordinates = "[current_x],[current_y]"
			if(STR.validate_grid_coordinates(final_coordinates, I.grid_width, I.grid_height, I))
				return final_coordinates
	return null

// Save every human currently in the round, as they are (including the dead,
// mirroring the restart save). Returns list("saved" = n, "failed" = n,
// "duration_ds" = deciseconds). Timed with world.realtime, not world.time:
// world.time only advances once per tick, so a save that finishes inside
// one tick would read as taking no time at all.
/proc/persistence_save_all_characters()
	var/start = world.realtime
	var/saved = 0
	var/failed = 0
	for(var/mob/living/carbon/human/H in GLOB.human_list)
		var/datum/character_save/CS = new /datum/character_save()
		if(CS.save_character(H))
			saved++
		else
			failed++
			log_admin("Persistence: failed to save [H.real_name] ([H.ckey]) during a manual save. Reason: [CS.save_error].")
	return list("saved" = saved, "failed" = failed, "duration_ds" = world.realtime - start)

// World-save entry point. Prototype 2 implements the world save; until then
// this reports as not yet implemented instead of failing silently.
/proc/persistence_save_world()
	return FALSE
