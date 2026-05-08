# Cinos Curse — 3.3.5a Cursive-style Curse/DoT Tracker

A Wrath of the Lich King (3.3.5a) addon inspired by **Cursive** by pepopo978
(https://github.com/pepopo978/Cursive). The goal is to replicate Cursive's
**target-tracking bars** and **click-to-target / quick-DoT** workflow on
a 3.3.5a client. Auto-targeting / priority-based "multicurse" is
**explicitly out of scope** for v1 — the secure-action model on Wrath makes
that fragile, and the click-driven workflow is what we actually want.

---

## Scope

### In scope (v1)
- A vertical stack of bars on screen, one per "interesting" hostile mob
  the addon is currently aware of.
- Each bar shows:
  - Mob name
  - Health bar (raw % or current/max if known)
  - Raid mark icon (if any)
  - Up to N small icons for the player's curses/DoTs on that mob, each
    with a CD-style swipe + remaining-time text
- **Left-click** a bar → target that mob (`/targetexact <name>` via
  secure macrotext).
- **Right-click** a bar → cast a configured "quick curse" on that mob via
  `[@mouseover]` while the cursor is over the bar (so the player's main
  target is preserved).
- Movable / lockable anchor frame.
- SavedVariables for: position, locked state, max bar count, quick-curse
  spell name, list of tracked spell names, ignored mob name substrings.

### Explicitly out of scope (v1)
- Auto target selection (`HIGHEST_HP`, `RAID_MARK`, etc. from Cursive).
- Nampower integration / improved range checking.
- Resist / expiry sounds (can come in v1.1).
- Shared-debuff dimming (Faerie Fire etc.).
- Bleed-immune verification (Rake-style).

### Maybe in scope (v1.1+)
- Sounds on resist / expiring.
- Per-class default tracked-spell lists (warlock curses + corruption etc.,
  shadow priest DoTs, balance druid DoTs, affliction-ish setups).
- Highlighting the "best" target (sort/color), without auto-casting —
  player still clicks.
- Optional cast-on-left-click mode for players who want one-button DoT.
- Configurable click bindings (Clique-style: shift-left, ctrl-right, etc.)

---

## 3.3.5a constraints we are designing around

1. **Secure casting on hostile units requires a hardware event.** We never
   try to cast from `OnUpdate` or from event handlers. All casts originate
   from a `SecureActionButton` click.
2. **Macrotext / unit attributes cannot be changed during combat** on a
   secure button. Strategy: use a fixed pool of N secure bar slots
   (default 10). Each slot's macrotext is rewritten **only outside combat**;
   during combat we update the *visual* contents (name, hp, icons) freely
   but leave the secure macrotext alone. If a slot's mob disappears
   mid-combat, the bar visually clears but the secure click still resolves
   to the last-set `/targetexact <name>` — harmless (will just say "no
   such target").
3. **`/targetexact <name>`** is the cleanest way to target an arbitrary
   mob. Limitation: with two identical names you get the nearest. Good
   enough for raids/dungeons in practice.
4. **Nameplate scanning** on 3.3.5: walk `WorldFrame:GetChildren()`,
   identify nameplates by their region structure, hook
   `OnShow`/`OnHide`. We use this only to *discover* mob names; we do
   not parent secure buttons to nameplates.
5. **GUIDs are first-class** in 3.3.5 (`UnitGUID`, combat log
   destGUID/sourceGUID). All curse-timer state is keyed by GUID.
6. **`UnitDebuff`** gives us exact remaining duration when a unit token
   resolves to the mob; combat-log inference is the fallback for mobs we
   only know by name/GUID.

---

## Architecture

```
CinosCurse/
  CinosCurse.toc
  core.lua          -- addon table, event dispatch, SavedVariables init
  scanner.lua       -- discovers mobs (nameplates, raid targets, target,
                      mouseover, focus), maintains nameByGuid + guidByName
  curses.lua        -- combat-log driven curse/DoT timer store keyed by
                      destGUID; UnitDebuff reconciliation when a token
                      resolves
  ui.lua            -- anchor frame, bar pool (N SecureUnitButtons),
                      visual update loop (OnUpdate throttled)
  bar.lua           -- single-bar widget factory: name text, hp bar,
                      raid mark, debuff icon row
  config.lua        -- defaults + SavedVariables shape, slash command
  Localization.lua  -- enUS strings only for now
  README.md
  PLAN.md           (this file)
```

### Data flow

1. **scanner.lua** keeps two maps:
   - `guidByName[name] = guid`
   - `nameByGuid[guid] = name`
   plus a `seen[guid] = lastSeenTimestamp` table for expiry.
   It populates these from any unit token it can reach: `target`,
   `mouseover`, `focus`, `raid1target..raid40target`, `party1target..`,
   `pet`, `pettarget`, and from nameplate scanning.
2. **curses.lua** subscribes to `COMBAT_LOG_EVENT_UNFILTERED`. For events
   where `sourceGUID == UnitGUID("player")` and `subEvent` is one of
   `SPELL_AURA_APPLIED|SPELL_AURA_REFRESH|SPELL_AURA_REMOVED|SPELL_DAMAGE`
   on a tracked spell, it updates `state[destGUID][spellName] =
   {start, duration, expiration}`. When a unit token is currently on that
   GUID, it reconciles via `UnitDebuff` to get exact expiration.
3. **ui.lua** runs a throttled OnUpdate (~5 Hz). It asks scanner for the
   current top-N mobs (priority: raid mark > current target > recently
   damaged > others), assigns them to bar slots, and updates the visual
   state. Secure macrotext on each slot is only rewritten when:
   `not InCombatLockdown()` AND the slot's currently-assigned mob name
   changed.
4. **bar.lua** widgets are dumb: they expose `:SetMob(name, guid)`,
   `:SetHealth(pct)`, `:SetRaidMark(idx)`, `:SetDebuffs(list)`,
   `:Clear()`.

### Secure click bindings

Each bar is a `Button` with `"SecureActionButtonTemplate"`:
- `*type1 = "macro"`, `macrotext = "/targetexact " .. name`
- `*type2 = "macro"`, `macrotext = "/cast [@mouseover] " .. quickCurse`

The frame itself sets `RegisterForClicks("AnyUp")`. We let mouseover
naturally land on the bar, so the `[@mouseover]` clause resolves to the
mob *only after* the player has targeted it once (because `mouseover` on
a non-unit-frame doesn't carry a unit). Open question / decision below.

#### Open design question: how does `[@mouseover]` see the bar's mob?

`SecureUnitButton_OnLoad`-style buttons can carry a `unit` attribute and
participate in mouseover resolution. But our bar's "unit" is a transient
mob discovered by name. Options:

- **Option A (chosen for v1):** When the player hovers a bar, we
  `OnEnter` set the bar's `unit` attribute to the appropriate token
  *if* one is currently available (e.g., we cached `raid3target` for that
  GUID). Setting `unit` outside combat is fine; inside combat we cannot
  re-set it. So in combat, right-click cast falls back to: macrotext
  becomes `/cast [@target] <spell>` after a left-click target, i.e. the
  player needs to left-click first then right-click. Acceptable.
- **Option B (v1.1):** Implement a Clique-like secure handler using
  `SecureHandlerSetFrameRef` + snippet that resolves the unit at click
  time. More work, better UX.

We start with A and document the limitation.

---

## Implementation milestones

### M0 — Skeleton ✅
- Folder created.
- `PLAN.md` (this file).
- `CinosCurse.toc` listing the planned files (most are stubs for now).
- `core.lua` with addon table, ADDON_LOADED handler, slash command
  `/cinoscurse` printing "loaded".

### M1 — Anchor frame + bar pool (no logic) ✅
- `ui.lua` creates a movable, lockable anchor and N empty bars stacked
  beneath it. Built on `PLAYER_LOGIN` so SavedVariables are populated.
- `bar.lua` widget factory: each bar is a `Button` with
  `SecureActionButtonTemplate`, backdrop, name fontstring, hp StatusBar,
  raid-mark texture slot. Mixin methods: `SetMob`, `Clear`, `SetHealth`,
  `SetRaidMark`, `SetDebuffs` (stub).
- Slash subcommands wired:
  - `/cinoscurse lock` — disables mouse + hides anchor chrome.
  - `/cinoscurse unlock` — re-enables drag.
  - `/cinoscurse reset` — restores default CENTER position.
  - `/cinoscurse show` / `hide` — debug placeholder bars (removed in M2).
- Anchor position auto-saved on drag stop.
- No casting wiring on bars yet (deferred to M3 for left-click target,
  M5 for right-click quick-curse).

### M2 — Scanner ✅
- `scanner.lua` discovers hostile mobs from:
  - Unit tokens (target, targettarget, mouseover, focus, pet, pettarget,
    party1-4 targets, raid1-40 targets) polled every 0.25s and on
    relevant events (`PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`,
    `PLAYER_FOCUS_CHANGED`, `RAID_TARGET_UPDATE`, `UNIT_HEALTH`).
  - Nameplates (Blizzard 3.3.5 plates), identified by walking
    `WorldFrame:GetChildren()`, filtering on the
    "anonymous + has FontString + has Nameplates texture" heuristic, then
    reading the name FontString and the child StatusBar for HP%.
- Maintains `mobs[key]`, `guidByName`, `nameByGuid`. Nameplate-only
  entries are keyed `name:<mobname>` and migrate to GUID-keyed when a
  unit token reveals the GUID.
- Stale entries pruned after 6s without a sighting.
- `S:GetSorted(limit)` returns prioritized list:
  raid mark > current target > mouseover > highest HP > alpha.
- `ui.lua` runs a 5 Hz updater that pulls `GetSorted(maxBars)` and paints
  bars (name, hp, raid mark). `/cinoscurse dump` prints tracked mobs.
- Ignored-name substring filter wired to config `ignoredNames`.

### M3 — Click-to-target ✅
- Each bar's secure `type1`/`macrotext1` is set to
  `/targetexact <mobName>` whenever its mob assignment changes.
- `BarProto:ApplySecure()` checks `InCombatLockdown()` and defers the
  rewrite (`pendingName`) until `PLAYER_REGEN_ENABLED`, where
  `BarProto:FlushPending()` reapplies.
- `ui.lua` now uses a slot-assignment layer (`slotAssign[i]`) with two
  policies:
  - **Out of combat**: free reassignment; macrotext rewritten freely.
  - **In combat**: existing slot↔mob bindings are kept stable so what
    you click matches what you see. Stale mobs visually clear (secure
    macrotext stays — clicking a cleared slot is harmless if the mob
    is gone). Empty slots can only be repopulated with the same name
    they previously held; brand-new mobs entering combat wait for
    next out-of-combat refresh.
- `type2`/`macrotext2` reserved for the M5 quick-curse cast (currently
  populated with `/cast [@mouseover,harm,nodead] <quickCurse>` if
  configured, so right-click already works as a placeholder while
  hovering the bar).

### M4 — Curse tracking ✅
- `curses.lua` listens to `COMBAT_LOG_EVENT_UNFILTERED` and records all
  player-applied tracked auras keyed by `destGUID` -> normalized
  (lowercase, no rank) spell name.
- Default duration table covers common warlock + a few priest/druid
  DoTs as a fallback. `UnitDebuff` reconciles real `expirationTime`
  whenever a unit token resolves to that GUID, via
  `PLAYER_TARGET_CHANGED`, `UPDATE_MOUSEOVER_UNIT`,
  `PLAYER_FOCUS_CHANGED`, `UNIT_AURA`, and an opportunistic call
  during refresh.
- Stack count tracked via `_DOSE` events.
- Cleanup: `UNIT_DIED` from combat log wipes the GUID; periodic prune
  drops expired entries every second.
- `bar.lua` adds a 5-icon row anchored to the bar's right edge:
  texture, remaining-time text (red <3s), stack count overlay.
  Icons hide cleanly when the slot clears.
- `ui.lua` now calls `b:SetDebuffs(CC.curses:GetActive(guid))` in both
  out-of-combat and in-combat refresh paths.

### M5 — Quick-curse right-click ✅
- Right-click on a bar casts the configured `quickCurse` via
  `/cast [@mouseover,harm,nodead] <Spell>` (the bar itself satisfies
  the `mouseover` clause when hovered).
- `/cinoscurse quick <Spell Name>` slash subcommand sets it. Reapplies
  to all bars immediately (out of combat).
- Default: `Curse of Agony`.

### M6 — Polish ✅
- Priority sort already implemented in M2 (raid mark > target >
  mouseover > highest HP > alpha).
- Health bar already in M1; populated in M2.
- `/cinoscurse track <Spell>` / `untrack <Spell>` to extend the
  default tracked-spells set.
- `/cinoscurse ignore <substr>` / `unignore <substr>` for mob filter.
- `/cinoscurse size <N>` to resize bar pool (requires `/reload`
  because pool is built once at login).
- Slash dispatcher in `core.lua` now lowercases only the subcommand,
  preserving spell-name capitalization in the rest of the argument.

---

## Notes for future chat sessions

When picking this up in a new chat, the relevant context to re-supply:

1. **This file (`PLAN.md`)** — full design.
2. **The current state of the addon folder** — `dir CinosCurse` is enough
   to see which milestone we're on.
3. **The reference**: pepopo978/Cursive on GitHub. We are *inspired by*
   it, not porting line-for-line. The v1 surface is much smaller.
4. **Target client**: 3.3.5a (WotLK 12340). No Nampower, no SuperWoW.
5. **Test environment**: `c:\HellScreamWoW\Interface\AddOns\` is the
   live AddOns folder being used.

Key invariants to never violate:
- No secure attribute mutation inside combat.
- All casts originate from a hardware-event secure click.
- All curse state keyed by GUID, never by name.
- Bar slot count is fixed at addon load; visuals can change freely
  in combat, secure attributes cannot.
