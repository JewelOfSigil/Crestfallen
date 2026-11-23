/*
	Treasury — a physical vault players place in the world.

	SKELETON, for Derflammenwerfer to fill in. This file is the object itself: the
	numbers it holds and the ways a player touches it. The TGUI panel
	backend lives in treasury_tgui.dm, and the screen itself in
	tgui/packages/tgui/interfaces/TreasuryPanel.tsx.

	The design (from DESIGN.md): a treasury is multi-user. Balances
	are keyed by character name, never by a mob reference. The total is
	the sum of balances plus unattributed vaulted coin. Coin inserted
	but not yet assigned sits in a counter — a staging pool that is NOT
	counted in the total, and anyone can add to it or withdraw from
	it. Deposit claims the whole counter. A locked deposit by a balance
	holder adds to the total AND their balance; an unlocked deposit
	increases the total only. An unlocked withdrawal takes only from
	the total. The owner sets a minimum to open a balance. The owner
	holds the key; the key used on any MEISTER opens remote management.

	Implemented with AI architecting.
*/

/obj/structure/treasury
	name = "treasury"
	desc = "A strongbox for holding mammon."
	icon = 'icons/roguetown/misc/machines.dmi'
	icon_state = "treasury" // TODO: replace with a real sprite.
	density = TRUE
	anchored = TRUE
	// A plain-string id, generated in Initialize. This is what the
	// character save stores as primary_treasury_id, and what the
	// world save uses to match a sweep to its treasury. Never a
	// reference — references do not survive a savefile.
	var/treasury_id = ""
	// Balances, keyed by character name (a plain string), never by
	// a mob reference. name -> mammon.
	var/list/balances = list()
	// Total vaulted coin: the sum of balances plus unattributed coin.
	var/total = 0
	// The counter: inserted-but-unassigned coin. NOT counted in the
	// total. Anyone can add to it or withdraw from it.
	var/counter = 0
	// Whether the treasury is locked. A locked deposit by a balance
	// holder adds to the total AND their balance; an unlocked deposit
	// increases the total only. Anyone can withdraw from an unlocked
	// treasury; closing it re-locks it.
	var/locked = TRUE
	// The minimum a first deposit must meet to open a balance.
	// Existing balance holders can top up any amount.
	var/owner_minimum = 0
	// The lock id the owner's key must match (the peddler pattern:
	// a key whose lockid equals keycontrol opens it).
	var/keycontrol = ""
	// The character name of the creator, for key recovery.
	var/creator_name = ""

var/global/treasury_uid = 0

/obj/structure/treasury/Initialize(mapload)
	. = ..()
	if(!treasury_id)
		treasury_uid++
		treasury_id = "treasury-[treasury_uid]-[rand(1000,9999)]"

/obj/structure/treasury/attack_hand(mob/user)
	if(!ishuman(user))
		return
	var/mob/living/carbon/human/H = user
	open_treasury_tgui(H)

/obj/structure/treasury/attackby(obj/item/P, mob/user, params)
	if(ishuman(user) && istype(P, /obj/item/roguecoin))
		// TODO: add the coin's value to the counter and delete
		// the coin. The coin's value is P.get_real_price(). The
		// MEISTER does the same shape in ATM.dm attackby.
		// counter += P.get_real_price()
		// qdel(P)
		// playsound(src, 'sound/misc/coininsert.ogg', 100, FALSE, -1)
		return
	return ..()

/obj/structure/treasury/proc/get_balance_for(mob/living/carbon/human/H)
	// TODO: return this character's balance here, or 0.
	// Balances are keyed by character name, so look the name up in
	// the balances list.
	// return balances[H.real_name] || 0
	return 0

/obj/structure/treasury/proc/is_owner(mob/living/carbon/human/H)
	// TODO: return TRUE when this user holds the owner's key.
	// The peddler pattern (vendor.dm): a key whose lockid equals
	// keycontrol. Check the key in their hands, and keys on a keyring.
	return FALSE
