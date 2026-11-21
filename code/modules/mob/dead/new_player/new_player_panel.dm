/mob/dead/new_player/verb/new_player_panel()
	set category = "Preferences.New Player"
	set name = "Reopen Lobby Menu"
	return ui_interact(src)

/mob/dead/new_player/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "NewPlayerPanel", "Lobby Menu")
		ui.open()

/mob/dead/new_player/ui_state(mob/user)
	return GLOB.new_player_state

/mob/dead/new_player/ui_data(mob/user)
	var/list/data = ..()

	data["server_name"] = CONFIG_GET(string/servername)
	data["ticker_state"] = SSticker.current_state
	data["ready"] = ready
	data["migrant"] = client?.prefs?.is_active_migrant() || FALSE // turns null into 0
	data["active_character"] = client?.prefs?.real_name

	data["time_remaining"] = SSticker.GetTimeLeft()
	data["ready_count"] = SSticker.totalPlayersReady
	data["ready_jobs"] = SSlobbymenu.get_lobby_player_display()

	return data

/mob/dead/new_player/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return

	switch(action)
		if("ready")
			var/is_pregame = SSticker.current_state <= GAME_STATE_PREGAME
			if(is_pregame)
				if(ready == PLAYER_NOT_READY)
					if(SSticker.job_change_locked)
						to_chat(src, span_boldwarning("Setting up, roles are locked..."))
						return
					if(length(client.prefs.flavortext) < MINIMUM_FLAVOR_TEXT)
						to_chat(src, span_boldwarning("You need a minimum of [MINIMUM_FLAVOR_TEXT] characters in your flavor text in order to play."))
						return TRUE
					if(length(client.prefs.ooc_notes) < MINIMUM_OOC_NOTES)
						to_chat(src, span_boldwarning("You need at least a few words in your OOC notes in order to play."))
						return TRUE

					// Implemented with AI architecting.
					// Persistence: if this character has a saved state,
					// ask whether to use it at roundstart. The lobby is
					// a TGUI panel, so the question lives here, in
					// ui_act — not in the Topic ready handler, which the
					// lobby no longer uses. The answer is remembered on
					// the lobby player for the round.
					use_saved_state = FALSE
					saved_state_character = ""
					var/datum/character_save/CS = new /datum/character_save()
					if(CS.character_save_exists(ckey, client.prefs.real_name) && CS.load_character(ckey, client.prefs.real_name))
						var/saved_job = CS.job_title ? " ([CS.job_title])" : ""
						var/choice = alert(src, "A saved state exists for [CS.real_name][saved_job] from a previous round. Do you want to continue as that saved character?", "Saved character", "Use saved state", "Start fresh")
						use_saved_state = (choice == "Use saved state")
						saved_state_character = CS.real_name

					ready = PLAYER_READY_TO_PLAY
				else
					ready = PLAYER_NOT_READY
					// Persistence: unreadying forgets the saved-state
					// answer; readying up again asks anew.
					use_saved_state = FALSE
					saved_state_character = ""
			return TRUE
		if("migrants")
			client.prefs.migrant.show_ui()
			return TRUE
		if("manifest")
			client.view_actors_manifest()
			return TRUE
		if("observe")
			make_me_an_observer()
			return TRUE
		if("show_preferences")
			client.prefs.ShowChoices(src, PREFERENCE_TAB_CHARACTER_CREATOR)
			return TRUE
		if("show_options")
			client.prefs.ShowChoices(src, PREFERENCE_TAB_GAME_SETTINGS)
			return TRUE
		if("show_keybinds")
			client.prefs.ShowChoices(src, PREFERENCE_TAB_KEYBINDINGS)
			return TRUE
		if("late_join")
			// Determine relevant population cap.
			var/relevant_cap
			var/hpc = CONFIG_GET(number/hard_popcap)
			var/epc = CONFIG_GET(number/extreme_popcap)
			if(hpc && epc)
				relevant_cap = min(hpc, epc)
			else
				relevant_cap = max(hpc, epc)

			if(!SSticker?.IsRoundInProgress())
				to_chat(src, span_boldwarning("The game is starting. You cannot join yet."))
				return TRUE

			if(client && client.prefs.is_active_migrant())
				to_chat(src, span_boldwarning("You are in the migrant queue."))
				return TRUE

			var/timetojoin = 5 MINUTES
#ifdef ALLOWPLAY
			timetojoin = 1 SECONDS
#endif
#ifdef TESTSERVER
			timetojoin = 0
#endif
			if(SSticker.round_start_time)
				if(world.time < SSticker.round_start_time + timetojoin)
					var/ttime = round((SSticker.round_start_time + timetojoin - world.time) / 10)
					var/list/choicez = list("Not yet.", "You cannot join yet.", "It won't work yet.", "Please be patient.", "Try again later.", "Late-joining is not yet possible.")
					to_chat(src, span_warning("[pick(choicez)] ([ttime])."))
					return TRUE

			var/plevel = 0
			if(client)
				plevel = client.patreonlevel()

			if(!IsPatreon(ckey))
				if(SSticker.queued_players.len || (relevant_cap && living_player_count() >= relevant_cap && !(ckey(key) in GLOB.admin_datums) && plevel < 1))
					to_chat(src, span_danger("[CONFIG_GET(string/hard_popcap_message)]"))

					var/queue_position = SSticker.queued_players.Find(src)
					if(queue_position == 1)
						to_chat(src, span_notice("Thou art next in line to join the game. You will be notified when a slot opens up."))
					else if(queue_position)
						to_chat(src, span_notice("Thou art [queue_position-1] players in front of you in the queue to join the game."))
					else
						SSticker.queued_players += src
						to_chat(src, span_notice("Thou have been added to the queue to join the game. Your position in queue is [SSticker.queued_players.len]."))
					return TRUE

			// Implemented with AI architecting.
			// Persistence: if this character has a saved state, ask
			// whether to use it BEFORE the role list is shown. A yes
			// joins straight into the saved character (no role list,
			// no class menu); a no, no save, or a saved job that is no
			// longer available falls through to the role list as normal.
			// This is the latejoin button the lobby actually shows, so
			// the question has to live here as well as in the Topic
			// late_join branch.
			if(try_latejoin_saved())
				return TRUE

			LateChoices()
			return TRUE
