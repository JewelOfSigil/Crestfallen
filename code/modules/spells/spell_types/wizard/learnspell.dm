/datum/action/cooldown/spell/learnspell
	name = "Attempt to learn a new spell"
	desc = "Weave a new spell"
	button_icon_state = "book1"

	click_to_activate = FALSE
	self_cast_possible = TRUE

	charge_required = FALSE
	cooldown_time = 1 SECONDS

	primary_resource_type = SPELL_COST_NONE

	spell_requirements = SPELL_REQUIRES_HUMAN | SPELL_REQUIRES_SAME_Z
	spell_impact_intensity = SPELL_IMPACT_NONE

/datum/action/cooldown/spell/learnspell/cast(atom/cast_on)
	. = ..()
	var/mob/living/user = owner
	if(!istype(user) || !user.mind)
		return FALSE
	// Implemented with AI architecting.
	// A character who has learned spells by spending points gets one use
	// of this action per character load, so they can change their prepared
	// spells even after their picks are spent and without the spellbook.
	// The grant is consumed when the picker is opened.
	if(!user.mind.has_remaining_aspect_picks())
		if(!user.mind.load_learnspell_granted)
			return FALSE
		user.mind.load_learnspell_granted = FALSE
	var/datum/aspect_picker/picker = new(user, TRUE, user.mind.mage_aspect_config)
	picker.ui_interact(user)
	return TRUE
