# API limits and evidence

## Evidence used for this initial implementation

- Blizzard's Midnight addon API announcement states that combat-log events are no longer available to addons and Combat Log chat messages are KStrings that prevent parsing. It also describes Secret Values and `issecretvalue`. [Archived Blizzard announcement (PDF)](https://upload3.inven.co.kr/upload/2025/10/04/bbs/MidnightPublicAlphaAddonAPIChanges.pdf)
- Warcraft Wiki documents `C_ActionBar.IsCurrentAction(actionID)` for Forever 1.60.1. [API reference](https://warcraft.wiki.gg/wiki/API_C_ActionBar.IsCurrentAction)
- A current Forever addon documents the practical KString limitation: messages can be displayed but cannot safely be shortened/parsed. [Floating Combat Info's Forever notes](https://www.curseforge.com/wow/addons/floating-combat-info)
- The Forever community documentation describes a modern API direction and flags current Beta results as observations rather than commitments. [WoW Forever Addons](https://wowforeverwiki.org/addons)

The first item is the primary technical constraint. The other three are supporting, version-specific context, not a substitute for testing the installed client.

## Deliberate non-features

| Requested datum | Current implementation | Why |
| --- | --- | --- |
| Raw `COMBAT_LOG_EVENT_UNFILTERED` records | Not registered | The current Midnight guidance says combat-log events are unavailable to addons. |
| Parsed hit/miss/dodge/parry/block | Not produced | Parsing KString combat messages is specifically prohibited by the design. |
| Per-swing `isOffHand` | Marked unavailable | That flag was traditionally carried by raw combat-log events; no validated replacement is known. |
| Direct Heroic Strike queued-spell API | No assumption | The addon observes only `IsCurrentAction` for configured/detected action-bar slots. |
| Arbitrary on-disk log file | Not attempted | Addon sandboxing uses SavedVariables, written by the client on shutdown. |

## What an HS transition means

`hsState.active` means at least one configured/detected Heroic Strike action-bar slot returned true from the selected current-action API at the most recent scan. `inactive` means every checked slot returned false. `unknown` means no validated slot/API result was available. It is **not** proof that the next swing was altered, that a Heroic Strike landed, or that an off-hand swing had a particular result.

The sampler runs once per 0.10 seconds while a session is active. A transition timestamp is accurate only to that sampling interval plus UI/event scheduling. Action-bar events request an immediate rescan, but the same caveat applies.

## Compatibility policy

The `.toc` targets the observed 1.60.1 interface number (`160001`) but is intentionally small and guarded. APIs are checked before use, event registration is protected with `pcall`, and every missing/secret/error result is retained as a marker rather than silently converted to a value. The client build's `capabilities` record is part of every session.

If a later Forever build exposes a documented combat-event or off-hand API, add a feature only with a versioned validation case proving both that the event fires and that its fields are safe to persist.
