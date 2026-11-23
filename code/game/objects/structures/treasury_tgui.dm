/*
	Treasury TGUI backend — SKELETON, for Jon to fill in.

	This mirrors the MEISTER's atm_tgui.dm, which is the file to read
	beside this one. Five pieces, each doing one job:

	- open_treasury_tgui: opens the window. The string "TreasuryPanel"
	  is the interface name — it must match the .tsx file and the
	  component name in tgui/packages/tgui/interfaces/.
	- ui_state: when the window is allowed to stay open. The MEISTER
	  uses GLOB.human_adjacent_state, so it closes when you walk away.
	- ui_interact: hands the UI to SStgui, which reuses the window if
	  it is already open.
	- ui_data / ui_static_data: the numbers the screen shows. ui_data
	  refreshes; ui_static_data is sent once. Both return a list of
	  named values, and the .tsx reads them by those names.
	- ui_act: what happens when the player presses a button. It takes
	  an action string and a params list, calls a handler proc, then
	  SStgui.update_uis(src) so the screen refreshes. The action
	  strings here must match the act('...') calls in TreasuryPanel.tsx.

	Implemented with AI architecting.
*/

/obj/structure/treasury/proc/open_treasury_tgui(mob/user)
	var/datum/tgui/ui = SStgui.try_update_ui(user, src, null)
	if(!ui)
		ui = new(user, src, "TreasuryPanel")
		ui.open()

/obj/structure/treasury/ui_state(mob/user)
	return GLOB.human_adjacent_state

/obj/structure/treasury/ui_interact(mob/user, datum/tgui/ui)
	SStgui.try_update_ui(user, src, ui)

/obj/structure/treasury/ui_static_data(mob/user)
	var/list/data = list()
	// The id never changes, so it is static. The panel shows it so
	// the player can tell one treasury from another.
	data["treasury_id"] = treasury_id
	return data

/obj/structure/treasury/ui_data(mob/user)
	var/mob/living/carbon/human/H = user
	var/list/data = list()
	data["total"] = total
	data["counter"] = counter
	data["locked"] = locked ? TRUE : FALSE
	data["owner_minimum"] = owner_minimum
	// The viewer's own balance in this treasury, or 0.
	data["viewer_balance"] = istype(H) ? get_balance_for(H) : 0
	// TODO (Jon): is_owner — does this user hold the key? See
	// is_owner() in treasury.dm. is_holder — does this character
	// have a balance here?
	data["is_owner"] = FALSE
	data["is_holder"] = FALSE
	return data

/obj/structure/treasury/ui_act(action, list/params)
	. = ..()
	if(.)
		return
	var/mob/living/carbon/human/H = usr
	if(!istype(H))
		return TRUE
	if(!H.canUseTopic(src, BE_CLOSE))
		return TRUE
	switch(action)
		if("deposit")
			handle_deposit(H, params)
			SStgui.update_uis(src)
			return TRUE
		if("withdraw")
			handle_withdraw(H, params)
			SStgui.update_uis(src)
			return TRUE
		if("set_primary")
			handle_set_primary(H, params)
			SStgui.update_uis(src)
			return TRUE
		if("set_minimum")
			handle_set_minimum(H, params)
			SStgui.update_uis(src)
			return TRUE
		if("toggle_lock")
			handle_toggle_lock(H, params)
			SStgui.update_uis(src)
			return TRUE

/*
	The handlers below are empty on purpose — each is one action for
	Jon to fill in, following the design in DESIGN.md. The MEISTER's
	handle_withdraw_personal (atm_tgui.dm) is the shape to copy: read
	the amount from params, check it, move the money, play a sound,
	and say something.
*/

/obj/structure/treasury/proc/handle_deposit(mob/living/carbon/human/H, list/params)
	// TODO (Jon): Deposit claims the WHOLE counter. If this character
	// already has a balance here, add it to their balance (and the
	// total). If not, and the counter meets owner_minimum, open a
	// balance with it. If it does not meet the minimum, reject it and
	// leave the counter in place, and tell the player. Clear the
	// counter to 0 only when the deposit succeeds.
	return

/obj/structure/treasury/proc/handle_withdraw(mob/living/carbon/human/H, list/params)
	// TODO (Jon): Withdrawal takes ONLY from the total, never from
	// any balance — and only while the treasury is unlocked, or from
	// the withdrawer's own balance when it is locked. Read the amount
	// from params["amount"]. If the amount is more than the total
	// present, tell the player there is insufficient coin. Pay out in
	// coin piles (budget2change, as the MEISTER does).
	return

/obj/structure/treasury/proc/handle_set_primary(mob/living/carbon/human/H, list/params)
	// TODO (Jon): Mark this treasury as the character's primary, so
	// the world-save sweep sends their Meister balance here. Only a
	// balance holder can set a primary. The id is stored on the
	// character save as primary_treasury_id — that field already
	// exists, this just sets it.
	// H.primary_treasury_id = treasury_id
	return

/obj/structure/treasury/proc/handle_set_minimum(mob/living/carbon/human/H, list/params)
	// TODO (Jon): The owner sets the minimum to open a balance. Only
	// the owner (the key holder) may do this. Read the amount from
	// params["amount"] and store it in owner_minimum.
	return

/obj/structure/treasury/proc/handle_toggle_lock(mob/living/carbon/human/H, list/params)
	// TODO (Jon): Lock or unlock the treasury. Anyone can withdraw
	// from an unlocked treasury; closing it re-locks it. The key
	// holder (or the owner) locks it; anyone may unlock it to
	// deposit, and closing it with RMB re-locks it — the RMB close
	// is a separate interaction on the object itself, not this button.
	// locked = !locked
	return
