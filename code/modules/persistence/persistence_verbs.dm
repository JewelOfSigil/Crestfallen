// Prototype 1: the "Test World Save" admin verb (design section 3,
// Trigger 3). Test only: it saves the world and every character in the
// round right now, so the persistence system can be tested during a live
// round without waiting for a round to end.
//
// Joining is disabled while the save runs (SSticker.late_join_disabled —
// the same flag AttemptLateSpawn checks) and restored afterwards, whether
// the save completes or fails. The verb does NOT run the treasury sweep;
// that belongs to the restart trigger.
//
// DM has no try/catch, so a crash mid-save would skip the line that
// re-enables joining. The watchdog below covers that: the verb schedules
// it before the save starts, and it runs one tick later on its own thread
// (a crash in the verb's thread does not kill it). If the save is still
// marked running when the watchdog wakes, the save crashed, and the
// watchdog re-enables joining itself and logs it. On the normal path the
// save finishes in the same tick, the mark is already cleared, and the
// watchdog does nothing. The watchdog cannot finish a half-done save —
// characters saved before the crash stay saved, the rest do not.
//
// The world-save half is implemented by Prototype 2. Until then the verb
// reports it as not yet implemented instead of failing silently.

// TRUE while a manual Test World Save is running. The watchdog reads it.
GLOBAL_VAR_INIT(persistence_test_save_running, FALSE)

// Watchdog for the Test World Save verb: if the save crashed mid-run,
// re-enable joining. Runs one tick after the save starts; the save is
// synchronous and finishes in the same tick, so the mark is only still
// set if the save never returned.
/proc/persistence_test_save_watchdog(was_disabled)
	if(!GLOB.persistence_test_save_running)
		return
	GLOB.persistence_test_save_running = FALSE
	SSticker.late_join_disabled = was_disabled
	message_admins("Persistence: Test World Save crashed mid-run. Joining has been re-enabled automatically; the save is incomplete and must be re-run.")
	log_admin("Persistence: Test World Save watchdog re-enabled joining after a crashed save.")

/client/proc/cmd_admin_test_world_save()
	set category = "Server"
	set name = "Test World Save"
	set desc = "Save the world and every character now (persistence test). Blocks joining until done."

	if(!check_rights(R_ADMIN))
		return
	if(GLOB.persistence_test_save_running)
		to_chat(usr, span_warning("A Test World Save is already running."))
		return
	if(alert(usr, "Save the world and every character in the round now? Joining will be disabled until the save completes or fails.", "Test World Save", "Save", "Cancel") != "Save")
		return
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Test World Save")

	// Disable joining for the duration of the save, then restore whatever
	// the flag was before (it may already have been disabled).
	var/was_disabled = SSticker.late_join_disabled
	SSticker.late_join_disabled = TRUE
	GLOB.persistence_test_save_running = TRUE
	// Schedule the watchdog BEFORE the save starts, so it exists even if
	// the save crashes. It wakes one tick later and does nothing if the
	// save already finished.
	spawn(1)
		persistence_test_save_watchdog(was_disabled)
	var/list/result = persistence_save_all_characters()
	var/world_saved = persistence_save_world()
	GLOB.persistence_test_save_running = FALSE
	SSticker.late_join_disabled = was_disabled

	var/world_text = world_saved ? "saved" : "not yet implemented (Prototype 2)"
	var/msg = "Test World Save complete: [result["saved"]] character(s) saved, [result["failed"]] failed. World save: [world_text]."
	to_chat(usr, span_notice(msg))
	message_admins("Admin [key_name_admin(usr)] ran Test World Save: [result["saved"]] character(s) saved, [result["failed"]] failed. World save: [world_text]. Joining was disabled during the save and has been restored.")
	log_admin("[key_name(usr)] ran Test World Save: [result["saved"]] saved, [result["failed"]] failed, world [world_text].")
