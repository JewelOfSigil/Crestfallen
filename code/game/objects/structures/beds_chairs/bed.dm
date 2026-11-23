/* Beds... get your mind out of the gutter, they're for sleeping!
 * Contains:
 *		Beds
 *		Roller beds
 */

/*
 * Beds
 */
/obj/structure/bed
	name = "bed"
	desc = "A soft warm bed complete with sheets and pillows."
	icon_state = "bed"
	icon = 'icons/obj/objects.dmi'
	anchored = TRUE
	can_buckle = TRUE
	buckle_lying = 90
	resistance_flags = FLAMMABLE
	max_integrity = 100
	integrity_failure = 0.35
	var/buildstacktype
	var/buildstackamount = 2
	var/bolts = TRUE
	// Implemented with AI architecting: whether this bed is tavern
	// property (an inn bed), and so cannot be claimed as a home; and
	// the name of the character who has claimed it as their home, if
	// any. claimed_by is instance state, so the world save records it.
	var/tavern_property = FALSE
	var/claimed_by
	buckleverb = "lay"

// Implemented with AI architecting: claims this bed as the given
// character's home. One static home per character — claiming a new
// bed unclaims the old one. A tavern bed, a bedroll, and a bed
// claimed by someone else cannot be claimed. Returns TRUE when the
// bed is (now) theirs.
/obj/structure/bed/proc/claim_bed(mob/living/carbon/human/H)
	if(tavern_property)
		to_chat(H, span_warning("This bed belongs to the tavern — it cannot be claimed as a home."))
		return FALSE
	if(istype(src, /obj/structure/bed/rogue/bedroll))
		to_chat(H, span_warning("A bedroll is no home — only a place to rest on the road."))
		return FALSE
	if(claimed_by && claimed_by != H.real_name)
		to_chat(H, span_warning("This bed is already claimed by [claimed_by]."))
		return FALSE
	if(claimed_by == H.real_name)
		to_chat(H, span_notice("This bed is already yours."))
		return TRUE
	var/confirm = alert(H, "Claim [src] as your home? You will return here when you rejoin.", "Claim bed", "Yes", "No")
	if(confirm != "Yes")
		return FALSE
	var/obj/structure/bed/old_bed = H.claimed_home_bed
	if(old_bed && !QDELETED(old_bed) && old_bed != src)
		old_bed.claimed_by = null
		to_chat(H, span_notice("You give up your claim on [old_bed]."))
	claimed_by = H.real_name
	H.claimed_home_bed = src
	to_chat(H, span_notice("You claim [src] as your home."))
	return TRUE

// Implemented with AI architecting: gives up this bed's claim, if any.
// (The claiming character's own record is cleared by claim_bed when
// they take a new bed; a bed destroyed outright leaves a dangling
// record, which the character save validates away at save and load.)
/obj/structure/bed/proc/unclaim_bed()
	claimed_by = null

/obj/structure/bed/ComponentInitialize()
	. = ..()
	AddComponent(/datum/component/simple_rotation,ROTATION_ALTCLICK | ROTATION_CLOCKWISE, CALLBACK(src, PROC_REF(can_user_rotate)),CALLBACK(src, PROC_REF(can_be_rotated)),null)

/obj/structure/bed/proc/can_be_rotated(mob/user)
	return TRUE

/obj/structure/bed/proc/can_user_rotate(mob/user)
	var/mob/living/L = user

	if(istype(L))
		if(!user.canUseTopic(src, BE_CLOSE, FALSE))
			return FALSE
		else
			return TRUE
	else if(isobserver(user) && CONFIG_GET(flag/ghost_interaction))
		return TRUE
	return FALSE

/obj/structure/bed/setDir(newdir)
	..()
	handle_rotation(newdir)

/obj/structure/bed/proc/handle_rotation(direction)
	handle_layer()
	if(has_buckled_mobs())
		for(var/m in buckled_mobs)
			var/mob/living/buckled_mob = m
			buckled_mob.setDir(direction)

/obj/structure/bed/proc/handle_layer()
	if(has_buckled_mobs() && dir == NORTH)
		layer = ABOVE_MOB_LAYER
	else
		layer = OBJ_LAYER

/obj/structure/bed/deconstruct(disassembled = TRUE)
	if(!(flags_1 & NODECONSTRUCT_1))
		if(buildstacktype)
			new buildstacktype(loc,buildstackamount)
	..()

/obj/structure/bed/attackby(obj/item/W, mob/user, params)
	if(W.tool_behaviour == TOOL_WRENCH && !(flags_1&NODECONSTRUCT_1))
		W.play_tool_sound(src)
		deconstruct(TRUE)
	else
		return ..()

/obj/structure/bed/post_buckle_mob(mob/living/M)
	. = ..()
	M.update_cone_show()

/obj/structure/bed/post_unbuckle_mob(mob/living/M)
	. = ..()
	M.update_cone_show()
