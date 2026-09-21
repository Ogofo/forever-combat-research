# In-client validation procedure

This addon is a measurement aid, not a pre-validated combat parser. Perform and preserve this checklist for each Forever build used in analysis.

## Before data collection

1. Record the client build displayed by `/fcr status`; it is also saved in the session capabilities.
2. Log into a Warrior with Heroic Strike on a known action-bar slot. Run `/fcr slots N`, substituting that slot number.
3. Run `/fcr start smoke-test`, queue and cancel Heroic Strike several times, then run `/fcr stop` and fully exit WoW.
4. Open the SavedVariables export and confirm the smoke-test has `hs_transition` records. Confirm its `capabilities.heroicStrike` shows the configured slot and a non-unknown scan result.
5. Confirm that no `COMBAT_LOG_EVENT_UNFILTERED` capability is claimed. If a combat chat event is saved as `secret`, that is expected—not a failed text conversion.

Do not collect a statistical dataset until steps 1–5 pass on the same build and UI setup you intend to use.

## Per-session collection

1. Start a labelled session before the first pull: `/fcr start target-level-63-run-001`.
2. Confirm the initial `snapshot` contains player equipment/stats and the intended target metadata. Let the addon append a new target snapshot after target changes.
3. Perform one controlled condition per session: e.g., no Heroic Strike queued, or Heroic Strike deliberately queued before each eligible swing. Do not label a condition from the logger alone.
4. Stop with `/fcr stop`; exit the client cleanly before copying the SavedVariables file.
5. Reject sessions where `truncated` is true, `droppedRecords` is nonzero, HS state remains `unknown`, or target identity changed unexpectedly.

## What to validate manually

- **Queue indication:** Compare the addon's `/fcr status` result with the game's visible Heroic Strike action-button state while repeatedly queuing/cancelling it.
- **Slot mapping:** Move the spell to a different slot; `active` should become `unknown` or inactive until `/fcr slots` is updated.
- **Message accessibility:** Cause at least one combat-chat message. Inspect whether it is stored as `value` or `secret`; do not try to derive an outcome from a secret marker.
- **SavedVariables persistence:** Make a test session, exit fully, relaunch, and confirm the previous session remains in `ForeverCombatResearchDB.sessions`.
- **Target snapshot:** Switch targets of different levels/types and confirm a `target_changed` snapshot was appended.

## Interpretation guardrails

These records can establish that a particular action-bar button looked current at sampling time and can preserve safely exposed context. They cannot, on this client API alone, establish that Heroic Strike caused a particular main-hand/off-hand combat result. A valid attack-table study needs an independently accessible and timestamp-correlatable outcome source; keep that source and its synchronization method in the research record.
