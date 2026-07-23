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
Lazy loading does not weaken identity checks.

## Runtime execution policy

The active build has no global scheduler or retained per-event job registry.
High-frequency game signals update bounded indexes and wake at most one
feature-owned coalesced runner. Pet dispatch and graphics queues have explicit
capacities; loot uses named game events, a bounded orb microbatch and
ReadyForCollection signals instead of local physics. Disabling a feature clears
its connections/state. STOP and reload invalidate every active worker token.

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
active graph and models a 100,000-event burst with no retained backlog.
