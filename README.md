# Forever Combat Research

A deliberately conservative research logger for **WoW Forever 1.60.1**. It captures only data that the running client exposes safely, records what it could *not* observe, and saves sessions through SavedVariables for later analysis.

It is aimed at testing whether queuing Heroic Strike correlates with anything observable. It does **not** claim to measure an attack table, per-swing main-hand/off-hand attribution, or raw combat-log outcomes on the current Forever/Midnight API.

## Important limitation

The current public Midnight addon guidance says combat-log events are unavailable to addons and Combat Log chat messages are protected KStrings, so addons cannot parse them. This addon therefore intentionally does **not** register `COMBAT_LOG_EVENT_UNFILTERED` and does not infer hit/miss/dodge/parry or `isOffHand` from chat text.

It records every subscribed `CHAT_MSG_COMBAT_*` event as an *accessible-combat-message observation*. If the message is an ordinary safe string, it is saved verbatim; if it is a KString/Secret Value, it is saved as `secret` without attempting to inspect, convert, concatenate, or parse it. The event name and local timestamp remain available. This prevents a false appearance of complete combat-log coverage.

See [API limits and evidence](docs/API_LIMITS.md) and the [validation procedure](docs/VALIDATION.md).

## What is recorded

Each manual session begins with a player snapshot and a target snapshot. Target snapshots are also taken when `PLAYER_TARGET_CHANGED` fires.

- Player: name/GUID when safely exposed, class, level, equipment IDs/links when safely exposed, and available primary/combat-stat API results.
- Target: GUID/name/level/classification/creature type/player state when safely exposed.
- Heroic Strike queue state: action-bar slot scan plus `C_ActionBar.IsCurrentAction(slot)` (legacy fallbacks are capability-checked). State changes are timestamped; scans run at 10 Hz while recording.
- Supplementary accessible events: player spellcast lifecycle events and the supported combat-chat event set.
- Capability report: build info, API presence, successful event registration, detected Heroic Strike action-bar slots, and all data sources that remained unavailable.

`mainHand` / `offHand` equipment are captured in the snapshot. A per-swing MH/OH flag is explicitly marked unavailable unless a future, validated client API supplies one.

## Install

1. Download the repository ZIP or clone it.
2. Copy the `ForeverCombatResearch` folder into the Forever Beta client's `Interface/AddOns` folder. The current beta path is usually:

   ```text
   <World of Warcraft folder>\_classic_beta_\Interface\AddOns\
   ```

   The resulting file must be exactly:

   ```text
   <World of Warcraft folder>\_classic_beta_\Interface\AddOns\ForeverCombatResearch\ForeverCombatResearch.toc
   ```

3. Quit and restart WoW completely. At character select, open the menu button and choose **AddOns**, then enable **Forever Combat Research**. The menu location can vary between beta builds. If no AddOns item appears, the client did not discover any addon: re-check the exact final path above.
4. Log into a Warrior and type `/fcr status`.

## Usage

```
/fcr start [optional label]  -- start a new research session and write snapshots
/fcr stop                    -- finish the current session
/fcr status                  -- show session, capability, and buffer status
/fcr snapshot                -- append fresh player and target snapshots
/fcr slots 1,2,73            -- explicitly set Heroic Strike action-bar slots
/fcr slots auto              -- return to English-name auto-discovery
/fcr help
```

For reliable Heroic Strike observations, put a Heroic Strike rank on a visible action-bar slot and use `/fcr slots N` to configure that exact slot. `auto` only recognizes the English spell name; localized clients should configure slots explicitly.

While a session is active, the Combat Log chat frame announces each detected queue transition as `Heroic Strike queue: ACTIVE.` or `INACTIVE.` If no Combat Log chat frame is configured, the addon falls back to the default chat frame. This is a quick validation aid; it has the same 0.10-second sampling limitation as the saved records.

## Export

WoW addons cannot create arbitrary files. On a normal clean client shutdown, WoW serializes `ForeverCombatResearchDB` to:

```
WTF/Account/<ACCOUNT>/SavedVariables/ForeverCombatResearch.lua
```

That SavedVariables file is the export. Do not edit it while WoW is running. Copy it after exiting fully, retain the original, and attach it to analysis separately. The database is intentionally structured Lua data, not CSV, because it can contain safe strings, unavailable markers, and Secret-Value markers without pretending they are equivalent.

When `/fcr start` succeeds, the addon also calls the client API `LoggingCombat(true)`. On current Forever builds this enables the separate client combat-log file at `Logs/WoWCombatLog.txt`. The addon records the API result as a `combat_file_logging` record and never turns client combat logging off automatically; use `/combatlog` yourself if you later want to disable it.

The session buffer has a 75,000-record default cap. A session stores `droppedRecords` and a truncation diagnostic if it hits that cap; a truncated session is not suitable for a completeness claim.

## Test status

This repository contains static checks only; it has **not** been executed in a Forever client from this environment. Follow [docs/VALIDATION.md](docs/VALIDATION.md) before treating a session as evidence.

## License

MIT. See [LICENSE](LICENSE).
