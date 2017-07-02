// Air update stages
#define SSAIR_TURFS 1
#define SSAIR_EDGES 2
#define SSAIR_FIREZONES 3
#define SSAIR_HOTSPOTS 4
#define SSAIR_ZONES 5
#define SSAIR_DONE 6

/datum/controller/subsystem/air/var/static/list/part_names = list("turfs", "edges", "fire zones", "hotspots", "zones")

SUBSYSTEM_DEF(air)
	name = "Air"
	init_order = INIT_ORDER_AIR
	priority = 20
	wait = 2 SECONDS // seconds (We probably can speed this up actually)
	flags = SS_BACKGROUND // TODO - Should this really be background? It might be important.
	runlevels = RUNLEVEL_GAME | RUNLEVEL_POSTGAME

	var/cost_turfs = 0
	var/cost_edges = 0
	var/cost_firezones = 0
	var/cost_hotspots = 0
	var/cost_zones = 0

	var/list/currentrun = null
	var/stage = null

	// Updating zone tiles requires temporary storage location of self-zone-blocked turfs across resumes. Used only by process_tiles_to_update.
	var/list/selfblock_deferred = null

/datum/controller/subsystem/air/PreInit()
	// Initialize the singleton /datum/controller/air_system
	// TODO - We could actually incorporate that into this subsystem!  But in the spirit of not fucking with ZAS more than necessary, lets not for now. ~Leshana
	air_master = new()

/datum/controller/subsystem/air/Initialize(timeofday)
	air_master.Setup() // Initialize Geometry
	..()

/datum/controller/subsystem/air/fire(resumed = 0)
	var/timer
	if(!resumed)
		ASSERT(LAZYLEN(currentrun) == 0)  // Santity checks to make sure we don't somehow have items left over from last cycle
		ASSERT(stage == null) // Or somehow didn't finish all the steps from last cycle
		air_master.current_cycle++ // Begin a new air_master cycle!
		stage = SSAIR_TURFS // Start with Step 1 of course

	if(stage == SSAIR_TURFS)
		timer = world.tick_usage
		process_tiles_to_update(resumed)
		cost_turfs = MC_AVERAGE(cost_turfs, TICK_DELTA_TO_MS(world.tick_usage - timer))
		if(state != SS_RUNNING)
			return
		resumed = 0
		stage = SSAIR_EDGES

	if(stage == SSAIR_EDGES)
		timer = world.tick_usage
		process_active_edges(resumed)
		cost_edges = MC_AVERAGE(cost_edges, TICK_DELTA_TO_MS(world.tick_usage - timer))
		if(state != SS_RUNNING)
			return
		resumed = 0
		stage = SSAIR_FIREZONES

	if(stage == SSAIR_FIREZONES)
		timer = world.tick_usage
		process_active_fire_zones(resumed)
		cost_firezones = MC_AVERAGE(cost_firezones, TICK_DELTA_TO_MS(world.tick_usage - timer))
		if(state != SS_RUNNING)
			return
		resumed = 0
		stage = SSAIR_HOTSPOTS

	if(stage == SSAIR_HOTSPOTS)
		timer = world.tick_usage
		process_active_hotspots(resumed)
		cost_hotspots = MC_AVERAGE(cost_hotspots, TICK_DELTA_TO_MS(world.tick_usage - timer))
		if(state != SS_RUNNING)
			return
		resumed = 0
		stage = SSAIR_ZONES

	if(stage == SSAIR_ZONES)
		timer = world.tick_usage
		process_zones_to_update(resumed)
		cost_zones = MC_AVERAGE(cost_zones, TICK_DELTA_TO_MS(world.tick_usage - timer))
		if(state != SS_RUNNING)
			return
		resumed = 0
		stage = SSAIR_DONE

	// Okay, we're done! Woo! Got thru a whole air_master cycle!
	ASSERT(LAZYLEN(currentrun) == 0) // Sanity checks to make sure there are really none left
	ASSERT(stage == SSAIR_DONE) // And that we didn't somehow skip past the last step
	currentrun = null
	stage = null

/datum/controller/subsystem/air/proc/process_tiles_to_update(resumed = 0)
	if (!resumed)
		// NOT a copy, because we are supposed to drain active turfs each cycle anyway, so just replace with empty list.
		// We still use a separate list tho, to ensure we don't process a turf twice during a single cycle!
		src.currentrun = air_master.tiles_to_update
		air_master.tiles_to_update = list()

		//defer updating of self-zone-blocked turfs until after all other turfs have been updated.
		//this hopefully ensures that non-self-zone-blocked turfs adjacent to self-zone-blocked ones
		//have valid zones when the self-zone-blocked turfs update.
		//This ensures that doorways don't form their own single-turf zones, since doorways are self-zone-blocked and
		//can merge with an adjacent zone, whereas zones that are formed on adjacent turfs cannot merge with the doorway.
		ASSERT(src.selfblock_deferred == null) // Sanity check to make sure it was not remaining from last cycle somehow.
		src.selfblock_deferred = list()

	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	var/list/selfblock_deferred = src.selfblock_deferred

	// Run thru the list, processing non-self-zone-blocked and deferring self-zone-blocked
	while(currentrun.len)
		var/turf/T = currentrun[currentrun.len]
		currentrun.len--
		//check if the turf is self-zone-blocked
		if(T.c_airblock(T) & ZONE_BLOCKED)
			selfblock_deferred += T
			if(MC_TICK_CHECK)
				return
			else
				continue
		T.update_air_properties()
		T.post_update_air_properties()
		T.needs_air_update = 0
		#ifdef ZASDBG
		T.overlays -= mark
		#endif
		if(MC_TICK_CHECK)
			return

	ASSERT(LAZYLEN(src.currentrun) == 0)

	// Run thru the deferred list and processing them
	while(selfblock_deferred.len)
		var/turf/T = selfblock_deferred[selfblock_deferred.len]
		selfblock_deferred.len--
		T.update_air_properties()
		T.post_update_air_properties()
		T.needs_air_update = 0
		#ifdef ZASDBG
		T.overlays -= mark
		#endif
		if(MC_TICK_CHECK)
			return

	ASSERT(LAZYLEN(src.selfblock_deferred) == 0)
	src.selfblock_deferred = null

	// TODO - Consider some magic trick like calling ourselves to avoid the code duplication above. Perhaps?
	// /datum/controller/subsystem/air/proc/process_tiles_to_update(resumed = 0, defer_selfblocked = 1)
	// ...
	// if(defer_selfblocked && (T.c_airblock(T) & ZONE_BLOCKED))
	// ...
	// if(LAZYLEN(selfblock_deferred))
	// 	src.currentrun = selfblock_deferred
	// 	process_tiles_to_update(TRUE, FALSE)

/datum/controller/subsystem/air/proc/process_active_edges(resumed = 0)
	if (!resumed)
		src.currentrun = air_master.active_edges.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/connection_edge/edge = currentrun[currentrun.len]
		currentrun.len--
		if(edge) // TODO - Do we need to check this? Old one didn't, but old one was single-threaded.
			edge.tick()
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/process_active_fire_zones(resumed = 0)
	if (!resumed)
		src.currentrun = air_master.active_fire_zones.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/zone/Z = currentrun[currentrun.len]
		currentrun.len--
		if(Z) // TODO - Do we need to check this? Old one didn't, but old one was single-threaded.
			Z.process_fire()
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/process_active_hotspots(resumed = 0)
	if (!resumed)
		src.currentrun = air_master.active_hotspots.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/obj/fire/fire = currentrun[currentrun.len]
		currentrun.len--
		if(fire) // TODO - Do we need to check this? Old one didn't, but old one was single-threaded.
			fire.process()
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/process_zones_to_update(resumed = 0)
	if (!resumed)
		air_master.active_zones = air_master.zones_to_update.len // Save how many zones there were to update this cycle (used by some debugging stuff)
		if(!air_master.zones_to_update.len)
			return // Nothing to do here this cycle!
		// NOT a copy, because we are supposed to drain active turfs each cycle anyway, so just replace with empty list.
		// Blanking the public list means we actually are removing processed ones from the list! Maybe we could we use zones_for_update directly?
		// But if we dom any zones added to zones_to_update DURING this step will get processed again during this step.
		// I don't know if that actually happens?  But if it does, it could lead to an infinate loop.  Better preserve original semantics.
		src.currentrun = air_master.zones_to_update
		air_master.zones_to_update = list()

	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/zone/zone = currentrun[currentrun.len]
		currentrun.len--
		if(zone) // TODO - Do we need to check this? Old one didn't, but old one was single-threaded.
			zone.tick()
			zone.needs_update = 0
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/stat_entry(msg_prefix)
	var/list/msg = list(msg_prefix)
	msg += "S:[stage ? part_names[stage] : ""] "
	msg += "C:{"
	msg += "T [round(cost_turfs, 1)] | "
	msg += "E [round(cost_edges, 1)] | "
	msg += "F [round(cost_firezones, 1)] | "
	msg += "H [round(cost_hotspots, 1)] | "
	msg += "Z [round(cost_zones, 1)] "
	msg += "}"
	if(air_master)
		msg += "T:[round((cost ? air_master.tiles_to_update.len/cost : 0), 0.1)]"
	..(msg.Join())
	if(air_master)
		air_master.stat_entry()


// Since air_master is still a separate controller from SSAir (Wait, why is that again? Get on that...)
// I want it showing up in the statpanel too. We'll just hack it in as a separate line for now.
/datum/controller/air_system/stat_entry()
	if(!statclick)
		statclick = new/obj/effect/statclick/debug(null, "Initializing...", src)

	var/title = "   air_master"
	var/list/msg = list()
	msg += "Zones: [zones.len] "
	msg += "Edges: [edges.len] "
	msg += "Cycle: [current_cycle] {"
	msg += "T [tiles_to_update.len] | "
	msg += "E [active_edges.len] | "
	msg += "F [active_fire_zones.len] | "
	msg += "H [active_hotspots.len] | "
	msg += "Z [zones_to_update.len] "
	msg += "}"

	stat(title, statclick.update(msg.Join()))


// Reboot the air master.  A bit hacky right now, but sometimes necessary still.
// TODO - Make this better by SSair and air_master together, then just reboot SSair
/datum/controller/subsystem/air/proc/RebootZAS()
	src.can_fire = FALSE // Pause processing while we reboot
	// If we should happen to be in the middle of processing... make sure that aborts
	if(!isnull(stage))
		currentrun = null
		selfblock_deferred = null
		stage = SSAIR_DONE

	var/datum/controller/air_system/old_air = global.air_master
	// Invalidate all zones
	for(var/zone/zone in old_air.zones)
		zone.c_invalidate()
	// Destroy the air_master and create a new one.
	qdel(old_air)
	global.air_master = new
	air_master.Setup()

	src.can_fire = TRUE // Unpause

#undef SSAIR_TURFS
#undef SSAIR_EDGES
#undef SSAIR_FIREZONES
#undef SSAIR_HOTSPOTS
#undef SSAIR_ZONES
#undef SSAIR_DONE
