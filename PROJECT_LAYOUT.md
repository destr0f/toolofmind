# PSX OG runtime layout

`runtime_manifest.json` is the single machine-readable map of the active build.
It owns the suite version, every runtime dependency URL/commit, exact byte count,
SHA-256, runtime DJB2 checksum, compatibility declaration and repository layout.

## Active runtime graph

`slim_farm.lua` is the readable source entry. `build_slim.js` validates and
compacts it into the published `loader.lua` and `toolofmind.lua` artifacts.
The generated entry embeds the validated runtime subset of the manifest.

At startup the generated entry:

1. validates the manifest schema and exact suite compatibility;
2. logs the version, commit and hashes of the main source, WindUI and every
   declared module;
3. verifies downloaded byte length and DJB2 before `loadstring`;
4. asks modules that expose a read-only `version` action to confirm their exact
   version before caching the controller.

WindUI and `automation_ui_module.lua` are startup dependencies. The remaining
modules are declared at startup but downloaded only when their feature is used.
`pet_farm_lite_engine.lua` owns the event-driven assignment writer and
`loot_reactor.lua` owns the only orb/lootbag subscriptions. Lazy loading does
not weaken identity checks.

`enchant_module.lua` owns the equipped-pet enchant pipeline. It resolves only
the stable named `Enchant Pet` command, keeps one UID selected until an exact
`Save.Pets[uid].powers` change is observed, accepts any selected live power-tier
title, and permits only one request in flight. It never depends on a floating
ReplicatedStorage child index or the game's two-second visual animation delay.

## Runtime execution policy

The active build has no global scheduler, profiler, timer heap or retained
per-event job registry. High-frequency game signals update bounded current-state
indexes and wake at most one feature-owned coalesced runner.

- Coins receive one initial folder scan and one initial `Get Coins` snapshot per
  world. `ChildAdded`, `ChildRemoved` and named coin deltas maintain the live
  registry afterwards.
- Pet allocation is event-driven. Accepted pets stay locked until their target
  disappears; one eight-wide writer owns Join/Target/Farm traffic and permits
  only one delayed retry. `Update Coin Pets` is intentionally outside the hot
  path, so other players cannot trigger a full local contention rebuild.
- The Orbs LocalScript is gated at its global `AddOrb` producer when `getsenv`
  is available. IDs are deduplicated into one current set and sent in a shared
  0.25-second native batch before Parts, billboards or body movers are created.
  Headless mode similarly no-ops only the Coins visual producers while the
  source registry continues to consume named server deltas. Unsupported
  executors fall back to read-only folder IDs without changing physics.
- Graphics performs one bounded pass over `__MAP`, `Lighting`, `__DEBRIS` and
  existing farm roots. It does not subscribe to high-rate Coins/Orbs/debris
  descendants and has no delayed second pass. Only top-level Pets, Eggs and
  Machines additions are observed. Geometry remains intact while safe visual
  textures/material maps are stripped in place. Player UI, camera and Network
  containers are never traversed.

Disabling a feature clears its connections/state. STOP and reload invalidate
every active generation, empty current registries, clear remote caches and
disconnect the graphics/loot roots.

## Intentional bounded scans and waits

The source audit intentionally leaves only the following cases:

- the module-loader wait is an on-demand serialization gate with a 45-second
  deadline; it is not a background worker;
- the player currency fallback scans only the local player's descendants;
- area bounds scan only the current `__MAP.Areas` hierarchy when the world
  changes;
- graphics walks explicit roots through one bounded `GetChildren()` queue and
  observes only low-rate top-level Pets/Eggs/Machines additions;
- bounded `while` loops drain fixed queues (16 assignment lanes or 256 initial
  FX objects), never the whole world per frame;
- one `Heartbeat:Wait()` yields between staged UI construction groups;
- anti-AFK's short wait runs only when Roblox emits `Player.Idled`.

Diamond/reward/UI scheduling is implemented with one generation-safe delayed
callback per feature. There are no active `task.spawn` workers in the main,
farm, loot or graphics hot paths.

## Repository categories

- `source`: editable runtime source and the manifest.
- `generated`: build output; never edit by hand.
- `vendor`: immutable local copies used to verify external releases.
- `build`: the active build pipeline.
- `tests`: policy and manifest verification.
- `documentation`: human-readable project maps.
- `legacy`: old loader experiments and payload fragments not reachable from the
  active runtime graph.

Generated files remain at the repository root because existing GitHub raw URLs
depend on those paths. Separation is enforced by the manifest and build checks,
not by moving public entrypoints.

## Build

Run:

```powershell
node build_slim.js
node tests/zero_retention_reactor_test.js
node tests/runtime_manifest_test.js
```

The build fails if a tracked file is unclassified, a file appears in two
categories, the suite version drifts, a pinned Git blob changes, a vendored
dependency differs from its release identity, or a generated artifact is stale.
The zero-retention test also checks the removed scheduler cannot re-enter the
active graph, validates the native loot/pet boundaries and models a
100,000-event burst with no retained backlog.

## Develop performance wishlist

### Remote farming and reward-settlement parity

Observed on `1.4.1-dev.22` with the same Tech Coins farm:

- standing in the farm location: approximately `+3.79T` over the last 60 seconds;
- standing at the egg location while auto hatch is active: approximately
  `+3.04T` over the last 60 seconds;
- measured short-window deficit: approximately `0.75T/min`, or `19.8%` relative
  to the in-zone sample.

Treat the measurements as a reproducible lead, not a confirmed constant. The
desired outcome is location-independent pet dispatch and complete server-side
reward settlement without reintroducing orb physics, visual teleportation or
unbounded retries. The investigation must separate:

1. player distance from the target zone;
2. auto-hatch and inventory/delete request contention;
3. pet free-to-dispatch and dispatch-to-working latency;
4. delayed, rejected, expired or unclaimed orb IDs;
5. streamed-out targets versus the named server coin catalog.

The comparison matrix is: in-zone/no eggs, remote/no eggs, remote/Native eggs,
remote/Headless eggs, then each remote case with direct loot disabled and
enabled. Each case should run for at least ten minutes and record balance delta,
working/joining pets, target gaps, Join Coin rejects, route RTT and orb
queued/sent/rejected/expired counts. Do not optimize against one rolling
60-second boundary.

Candidate improvements, only after the matrix identifies the loss stage:

- preserve a server-fed target-ID cache when the farm zone is streamed out;
- hand a freed pet directly to its next cached target before it can return to
  the player;
- keep farm dispatch independent from egg and inventory post-processing lanes;
- coalesce Claim Orbs adaptively with one request in flight and a bounded
  catch-up batch;
- distinguish accepted reward IDs, stale IDs and transport failures so only
  genuine transport failures can retry;
- expose settled-value rate alongside raw target destruction rate.

Acceptance requires remote Headless farming to remain within 5% of the in-zone
ten-minute baseline with zero dropped loot IDs, no live-target switching and no
regression in FPS, memory or producer-gate health. The longer-term upside target
is recovering the observed 20-30% loss before considering separate damage or
farm-strength upgrades.
