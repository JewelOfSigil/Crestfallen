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
// The world-save half is implemented by Prototype 2. Until then the verb
// reports it as not yet implemented instead of failing silently.

/client/proc/cmd_admin_test_world_save()
	set category = "Server"
	set name = "Test World Save"
	set desc = "Save the world and every character now (persistence test). Blocks joining until done."

	if(!check_rights(R_ADMIN))
		return
	if(alert(usr, "Save the world and every character in the round now? Joining will be disabled until the save completes or fails.", "Test World Save", "Save", "Cancel") != "Save")
		return
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Test World Save")

	// Disable joining for the duration of the save, then restore whatever
	// the flag was before (it may already have been disabled).
	var/was_disabled = SSticker.late_join_disabled
	SSticker.late_join_disabled = TRUE
	var/list/result = persistence_save_all_characters()
	var/world_saved = persistence_save_world()
	SSticker.late_join_disabled = was_disabled

	var/world_text = world_saved ? "saved" : "not yet implemented (Prototype 2)"
	var/msg = "Test World Save complete: [result["saved"]] character(s) saved, [result["failed"]] failed. World save: [world_text]."
	to_chat(usr, span_notice(msg))
	message_admins("Admin [key_name_admin(usr)] ran Test World Save: [result["saved"]] character(s) saved, [result["failed"]] failed. World save: [world_text]. Joining was disabled during the save and has been restored.")
	log_admin("[key_name(usr)] ran Test World Save: [result["saved"]] saved, [result["failed"]] failed, world [world_text].")
