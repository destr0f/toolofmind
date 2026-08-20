# Active Network4/Network5 Route Manifest

Suite: `1.4.1-candidate.54.34-native-farm-feed`

Evidence used:

- active source graph in `runtime_manifest.json`;
- Cobalt archive session `20260813_170240` and its 45 route snapshots;
- Cobalt archive session `20260815_192259`: 36,382 calls, 67 unique
  signatures and 401 full snapshots from the current Network layout;
- Cobalt archive session `20260820_084121`: 40,620 traffic records over
  roughly 656 seconds, 89 unique calls, 534 snapshots and zero recorder
  drops/errors;
- `PSX_COBALT_NETWORK_CONSPECT_20260813.md`;
- command call sites in `slim_farm.lua`, `pet_farm_lite_engine.lua`, `loot_reactor.lua`, `auto_egg_module.lua`, machine, boost, enchant and reward workers.

`Captured` means the current Cobalt archive contains a matching call and payload. `Source` means the command is active and its contract is established by the game's decompiled caller and this project's previously working module, but the current 45-call capture did not exercise it.

## Resolver contract

1. The primary identity is `(kind, logical command name)`, never `GetChildren()[index]` and never a physical hash copied from another session.
2. The active resolver reads the live command-to-hash and hash-to-instance maps from `ReplicatedStorage.Framework.Modules.Client.2 - Network` without executing its RobloxScript-bound accessor.
3. Physical remote names are session-bound. The current resolver first reads
   the live command map, then computes the current same-session Network5 VLG
   identity. A hash copied from Cobalt traffic is never a persistent command
   identity.
4. The current Network5 VLG identity, confirmed by Cobalt session
   `20260820_084121`, is:

   ```text
   sha256("PSXOG:SECRET:NETWORK:VLG:12910259120591716249102/Network5/"
       + GameId + "/" + PlaceId + "/" + PlaceVersion + "/" + JobId
       + "/" + kind + "/" + command):sub(5, 36)
   ```

   `kind=1` is `RemoteEvent`; `kind=2` is `RemoteFunction`. After materialising
   a route, the game renames the instance to its generic class and stores the
   original hash in its `NetworkHash` attribute. Therefore the cold path may do
   one bounded direct-child scan for that exact attribute. Plain DJB2 remains
   legacy compatibility only.
5. A resolved instance must have the expected class and be a descendant of `ReplicatedStorage`. Bindable bridges are accepted only when the live Network table actually exposes a matching live bridge. Upvalue #2 is a route-map table in the current layout and must never be invoked as a lazy accessor.
6. Route caches are scoped to the runtime generation. A transport failure invalidates only the exact `(kind, command, expected instance)` route. Named `Library.Network.Fire/Invoke` is the final compatibility fallback and receives the first current live alias (`Join The Coin`, `Change Pet Target NOW`, `Farm The Coin`) rather than the project's legacy logical name.
7. Local `FireServer` success is transport commitment, not server acknowledgement. `InvokeServer` results are returned to the caller but completed state-changing responses are never replayed.

## Outbound RemoteFunctions

| Project command | Live name / aliases | Arguments, in order | Result used by runtime | Confirmation | Replay | Evidence |
|---|---|---|---|---|---|---|
| `Get Coins` | `Get Coins Data`, `Get The Coins`, `Get Coins` | none | coin catalog table keyed by coin ID | valid non-empty table, then live coin deltas | read-only startup/world-change snapshot only | Captured |
| `Join Coin` | `Join Coin mmm`, `Join The Coin`, `Join Coin` | `coinId`, `{petUid...}` | table/map of accepted pet UIDs, or boolean rejection | returned UID map; later `Update Coin Pets`, health and removal are state events | forbidden | Captured; native batch 16 |
| `Leave Coin` | `Leave Coin mmm`, `Leave The Coin`, `Leave Coin` | `coinId`, `{petUid...}` | boolean/message when supplied | function result; used only during reset/explicit release | forbidden | Captured |
| `Buy Egg Yay` | `Egg: Buy Egg`, `Buy Egg Ok`, `Buy Egg Yay` | `eggName`, `triple:boolean` | boolean plus hatch payload/message depending game path | function result, then `openegggg`/`Opening Egg` or exact inventory delta | forbidden | Captured |
| `Delete Several Pets` | same | `{petUid...}` | boolean/message | exact inventory delta | forbidden | Captured |
| `Enchant Pet` | same | `petUid` | boolean/result payload | changed enchant in `Save.Pets` | forbidden | Source |
| `Get Golden Machine Info` | same | none | machine tier table | valid tier table, cached after success | read-only result cache allowed | Source |
| `Use Golden Machine` | same | `{petUid...}` | boolean/message | `Save.Pets` version change | forbidden | Source |
| `Get Rainbow Machine Info` | same | none | machine tier table | valid tier table, cached after success | read-only result cache allowed | Source |
| `Use Rainbow Machine` | same | `{petUid...}` | boolean/message | `Save.Pets` version change | forbidden | Source |
| `Get OSTime` | same | none | numeric server time | numeric result, then advanced locally | read-only result cache allowed | Source |
| `Get Dark Matter Machine Info` | same | none | machine tier table | valid tier table, cached after success | read-only result cache allowed | Source |
| `Convert To Dark Matter` | same | `{petUid...}` | boolean/message | Dark Matter queue / pet inventory delta | forbidden | Source |
| `Redeem Dark Matter Pet` | same | `queueEntryId` | boolean/message | queue removal and pet inventory delta | forbidden | Source |
| `Buy Boost Bundle` | same | none | boolean/message | `BoostsInventory` increase | forbidden | Source |
| `Redeem VIP Rewards` | same | none | boolean/message | server result and local reward timer/save update | forbidden | Source |
| `Redeem Rank Rewards` | same | none | boolean/message | server result and local rank timer/save update | forbidden | Source |
| `Redeem Free Gift` | same | `giftIndex:number` | `boolean, message?` | function result and `FreeGiftsRedeemed` update | forbidden | Captured |
| `Buy DiamondPack` | same | `tier:number` (`4` in this suite) | boolean/message | function result and diamond/currency delta | forbidden | Source |

Every row resolves through `resolveFunction`; the active command wrapper tries the verified RemoteFunction, a real command-specific BindableFunction bridge if present, then the named invoke fallback. Machine info and `Get OSTime` are the only active read-only results intentionally retained after a successful response.

## Outbound RemoteEvents

| Project command | Live name / aliases | Arguments, in order | Local send verification | Server/game confirmation | Retry rule | Evidence |
|---|---|---|---|---|---|---|
| `Change Pet Target` | `Change Pet Target NOW`, `Change Pet Target` | `petUid`, `"Coin"`, `coinId`; reset form `petUid`, `"Player"` | `pcall(FireServer)` | `Update Coin Pets`, health/removal state; absence of a local delta is not failure | only a genuine local transport failure | Captured |
| `Farm Coin` | `Farm Coin mmm`, `Farm The Coin`, `Farm Coin` | `coinId`, `petUid` | `pcall(FireServer)` | health/removal state | only a genuine local transport failure | Captured |
| `Claim Orbs` | same | `{orbId...}` | one successful local Fire commits each ID | `Orb Removed` is cleanup/statistics only | retry the same ID only after local Fire failure | Captured; native batches 1-40 observed, no hard limit 8 |
| `Collect Lootbag` | same | `lootbagId`, current `Vector3` | one successful local Fire closes the record | `Remove Lootbag` is optional cleanup/statistics | retry only after local Fire failure while the physical bag still exists | Captured |
| `Activate Boost` | same | boost name (`Triple Coins`, `Triple Damage`, `Super Lucky`, `Ultra Lucky`) | `pcall(FireServer)` | `Save.Boosts` timer change | worker retries only from its normal due-state after a real send failure | Captured |

Every row resolves through `resolveEvent`; a real command-specific BindableEvent bridge and the named fire fallback are compatibility paths. No RemoteEvent is reported as server-accepted merely because the local call returned.

## Inbound state routes

| Logical event | Payload used | Active consumer | Role |
|---|---|---|---|
| `New Coin` | `coinId, coinData` | `slim_farm.lua` | add/respawn authoritative target |
| `Update Coin Health` | `coinId, health` | `slim_farm.lua` | liveness/progress state; no resend trigger |
| `Update Coin Pets` | `coinId, complete pet membership` | `slim_farm.lua` | confirm membership or release only explicitly absent local pets |
| `Remove Coin` | `coinId` | `slim_farm.lua` | release every local pet on the removed target and fast-dispatch |
| `openegggg`, `Open Egg`, `Opening Egg` | egg name and pet result payload | `auto_egg_module.lua` | hatch acknowledgement and headless post-processing |
| `Orb Added` / producer `AddOrb` | orb ID plus owner/world payload | `loot_reactor.lua` | enqueue a deduplicated one-shot claim before visual allocation |
| `Orb Removed` | orb ID | `loot_reactor.lua` | clear bounded confirmation state only |
| `Spawn Lootbag` / producer `Add` | ID, payload/position | `loot_reactor.lua` | enqueue one native-compatible collect |
| `Remove Lootbag` / producer `Remove` | lootbag ID | `loot_reactor.lua` | optional acknowledgement and local cleanup |

Farm lifecycle events resolve through the transport adapter. In the captured
Network5 build, its primary path is the game's own `Library.Network.Fired(name)`:
the function returns the shared `t4[1][hash].OnClientEvent` or
`t2[1][hash].Event` used by game LocalScripts and performs no outbound request.
Verified direct discovery of the same `t4[1]`/`t2[1]` entries remains the
compatibility fallback. The farm never fabricates its own BindableEvent and
never treats `Connect` alone as proof that events are flowing. Missing
observations do not retroactively turn a successful outbound RemoteEvent into
a transport error.

## Cache and lifecycle policy

- `network4_transport_module.lua`: route/bridge caches contain only current-generation live instances; exact invalidation and full reload clear are separate operations.
- `pet_farm_lite_engine.lua`: `InvokeHistory` is deliberately empty; only identical currently-in-flight invokes may coalesce. Fire marks expire automatically and every transport map is cleared by start/reset/stop.
- `loot_reactor.lua`: pending orb IDs leave pending only after local send; successful IDs are never requeued because another ID received or missed `Orb Removed`.
- Reload increments the runtime generation, disconnects old workers, clears main route caches and invokes the adapter's full clear. No physical remote hash or session child index survives into a new generation.
