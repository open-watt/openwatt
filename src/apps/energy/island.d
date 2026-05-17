module apps.energy.island;

import urt.array;
import urt.lifetime;
import urt.mem;
import urt.string;

import apps.energy.circuit;

nothrow @nogc:


// An island's operational mode. Drives how the planner reasons about
// available headroom and acceptable grid-buy behaviour.
enum IslandMode : ubyte
{
    unknown,    // not yet determined (first tick, or transitional)
    on_grid,    // rooted at the configured grid circuit; can import/export
    off_grid,   // backup-rooted; no grid available, conservation posture
    forming,    // transitional (inverter switching modes); reserved for later use
}

const(char)[] island_mode_name(IslandMode m) pure
{
    final switch (m)
    {
        case IslandMode.unknown:  return "unknown";
        case IslandMode.on_grid:  return "on_grid";
        case IslandMode.off_grid: return "off_grid";
        case IslandMode.forming:  return "forming";
    }
}


// An Island is a connected subgraph of live circuits. Normally a site has one
// island (the main grid-tied tree); during a grid outage the tree fragments
// into one island per backup-rooted subtree, with dead branches absent from
// every island.
//
// Per-island resource accounts, pressures, and budget are added in subsequent
// Phase 0 work.
struct Island
{
nothrow @nogc:

    this(this) @disable;

    // Stable, derived from the root circuit's name. "main" reappears when the
    // grid comes back; backup-rooted islands inherit the backup circuit's id.
    String id;

    // Topmost live circuit of this connected subgraph.
    Circuit* root;

    // All live circuits in this island. Built each tick by the partition algorithm.
    Array!(Circuit*) members;

    // Operational mode. Derived from whether the island is rooted at the
    // configured grid circuit (on_grid) versus a backup-rooted fragment
    // (off_grid). Computed each tick by update_archipelago.
    IslandMode mode;
}


// Archipelago: the set of currently-existing islands. Normally length 1.
alias Archipelago = Array!(Island*);


// Recompute the archipelago for this tick. Reuses existing Island* slots when
// their id remains valid (history stays coherent across grid bounces); creates
// new Islands for newly-appearing ids and destroys those that have vanished.
void update_archipelago(ref Archipelago archipelago, Circuit* main)
{
    if (!main)
    {
        foreach (i; archipelago)
            destroy_island(i);
        archipelago.clear();
        return;
    }

    // 1. Walk the configured tree, find every "topmost-live" circuit. Each is
    //    the root of one island in the partition.
    Array!(Circuit*) new_roots;
    find_island_roots(main, new_roots);

    // 2. For each new root, find or create an Island with that id and (re-)populate
    //    its member list. Mode is derived from whether the root matches the
    //    configured grid circuit: rooted at `main` means on-grid, otherwise the
    //    island is a backup-rooted fragment (off-grid).
    foreach (root; new_roots[])
    {
        Island* island = find_or_create_island(archipelago, root);
        island.members.clear();
        collect_members(root, island.members);
        island.mode = (root is main) ? IslandMode.on_grid : IslandMode.off_grid;
    }

    // 3. Drop islands whose id is no longer present in the new partition.
    //    (Iterate backwards so swap-remove doesn't skip neighbours.)
    for (size_t i = archipelago.length; i-- > 0; )
    {
        Island* island = archipelago[i];
        bool kept = false;
        foreach (root; new_roots[])
        {
            if (root.id[] == island.id[])
            {
                kept = true;
                break;
            }
        }
        if (!kept)
        {
            destroy_island(island);
            archipelago.remove(i);
        }
    }
}


private:

void find_island_roots(Circuit* c, ref Array!(Circuit*) roots)
{
    // A circuit is an island root if it's live AND it has no live ancestor
    // connected by a non-isolated path. Equivalent: live AND (no parent OR
    // parent not live OR this circuit isolated from its parent).
    if (c.is_live && (!c.parent || !c.parent.is_live || c.isolated))
        roots ~= c;
    foreach (sub; c.sub_circuits[])
        find_island_roots(sub, roots);
}

void collect_members(Circuit* c, ref Array!(Circuit*) members)
{
    members ~= c;
    foreach (sub; c.sub_circuits[])
    {
        // Skip dead branches and isolated children (the latter are roots of
        // their own islands, partitioned separately).
        if (!sub.is_live || sub.isolated)
            continue;
        collect_members(sub, members);
    }
}

Island* find_or_create_island(ref Archipelago archipelago, Circuit* root)
{
    foreach (island; archipelago[])
    {
        if (island.id[] == root.id[])
        {
            island.root = root;
            return island;
        }
    }
    Island* island = defaultAllocator.allocT!Island();
    island.id = root.id;
    island.root = root;
    archipelago ~= island;
    return island;
}

void destroy_island(Island* island)
{
    defaultAllocator.freeT(island);
}
