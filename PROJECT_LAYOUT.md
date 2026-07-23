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

WindUI, `profiler_module.lua` and `automation_ui_module.lua` are startup
dependencies. The remaining modules are declared at startup but downloaded only
when their feature is used. Lazy loading does not weaken identity checks.

## Reproducible performance baseline

The Profiler tab can preload every manifest module without starting its feature,
then record one of eight exact configuration scenarios. A report includes:

- module/operation time with calls/sec and p50/p95/max;
- explicitly instrumented object scans and temporary hot-path tables;
- network, loot and inventory queue depth;
- inventory scans, UI updates and network calls;
- FPS, frame-time distribution, Lua memory and measured observer overhead;
- start/finish configuration, environment and manifest/module versions.

Reports are retained in `getgenv().PSX_OG_PROFILER_REPORTS` and exported to
`PSX_OG_Profiles/*.json` when the executor exposes `writefile`. This phase only
observes existing work: scenario validation never toggles automation, changes
intervals or applies Potato Mode.

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
node tests/runtime_manifest_test.js
luau tests/profiler_baseline_test.lua
```

The build fails if a tracked file is unclassified, a file appears in two
categories, the suite version drifts, a pinned Git blob changes, a vendored
dependency differs from its release identity, or a generated artifact is stale.
