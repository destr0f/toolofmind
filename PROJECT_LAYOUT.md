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
`pet_farm_engine.lua` owns the fixed-width assignment writer and
`loot_reactor.lua` owns the only orb/lootbag subscriptions. Lazy loading does
not weaken identity checks.

## Runtime execution policy

The active build has no global scheduler, profiler, timer heap or retained
per-event job registry. High-frequency game signals update bounded current-state
indexes and wake at most one feature-owned coalesced runner.

- Coins receive one initial folder scan and one initial `Get Coins` snapshot per
  world. `ChildAdded`, `ChildRemoved` and named coin deltas maintain the live
  registry afterwards.
- Pet allocation is event-driven. Accepted pets stay locked until their target
  disappears; one 16-wide writer owns Join/Target/Farm traffic and two bounded
  retries.
- Orb IDs are deduplicated into one current set and sent in a shared 0.25-second
  native batch. Lootbags wait on readiness signals and have one bounded retry.
- Farm FX observes only `__DEBRIS` and the Coins/Pets/Orbs/Lootbags roots. The
  map, camera, eggs, machines, UI and Network containers are never traversed.

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
- graphics calls `GetDescendants()` once when each narrow farm root is bound,
  then uses `DescendantAdded`; game-owned FX instances are deferred until their
  parent assignment completes and are disabled in place rather than destroyed;
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
