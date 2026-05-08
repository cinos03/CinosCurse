# Cinos Curse

A lightweight WotLK 3.3.5a addon inspired by the Vanilla addon
[Cursive](https://github.com/pepopo978/Cursive). It surfaces nearby
hostile mobs as a stack of clickable bars showing health, raid mark, and
your active curses / DoTs on each one — so you can dot-rotate across
multiple targets without retargeting.

![bars](images/bars.png)

## Features

- **Clickable target bars** for nearby mobs. Discovery works from any
  of: visible nameplates, your target / mouseover / focus, party &
  raid targets, pet target, **and the combat log** — so mobs your
  group is fighting (or that are hitting you) appear even without a
  visible nameplate.
- **GUID-precise targeting.** When a unit token resolves to a bar's
  specific mob, clicking targets that exact unit (not just the name) —
  important when several mobs share a name.
- **Left-click** = target this exact mob.
- **Right-click** = cast your configured *quick curse* on the mob via
  `[@mouseover]` (works without changing your current target).
- **Bars expose a real `unit` attribute** while you hover them, so any
  `[@mouseover]` macro you already have will fire on the bar's mob.
- **Per-mob debuff icons** with countdown text (red <3s) and stack
  counts. Tracks all warlock curses + Corruption / UA / Siphon Life /
  Haunt / Immolate / Shadowflame / CoD; SW:Pain / VT / Devouring
  Plague; Moonfire / Insect Swarm out of the box.
- **Bar named `CinosCurseBarN`** so `/click CinosCurseBar3` works for
  hotbar macros.
- **Sticky raid-marked mobs** with sort order Skull → X → Square →
  Moon → Triangle → Diamond → Circle → Star, so pre-pull marks lay
  out top-to-bottom in your specified order.
- **Stays alive while cursed.** A mob whose nameplate vanishes still
  keeps its bar as long as your DoTs are ticking on it (capped at
  30s without a sighting).
- **Target indicator** (`>` arrow) shows which bar is your current
  target, so tab-targeting through DoT'd mobs is at-a-glance.
- **Wipes on zone change.** Hearth / portal / death-and-release
  clears the bars instantly — no ghost mobs from the old zone.
- **Combat-safe.** All secure attribute writes are deferred while
  `InCombatLockdown()` and flushed on `PLAYER_REGEN_ENABLED`. New
  mobs entering combat still surface (just not clickable until combat
  ends if no name-match was already bound).
- **Cheap.** Fast path runs at 20 Hz, no per-frame table allocations,
  cached nameplate references.

## Slash commands

`/cc` or `/cinoscurse`:

| Command | Effect |
| --- | --- |
| `lock` / `unlock` | Hide/show the move handle. |
| `reset` | Reset anchor to screen center. |
| `show` / `hide` | Force bars on/off (debug). |
| `dump` | Print the current sorted mob list. |
| `quick <SpellName>` | Set the right-click quick-curse spell. |
| `track <SpellName>` | Add a custom debuff to track. |
| `untrack <SpellName>` | Remove one. |
| `ignore <substr>` | Hide mobs whose name contains substring. |
| `unignore <substr>` | Remove an ignore filter. |
| `size <w> <h>` | Resize bars. |

## Installation

1. Copy the `CinosCurse` folder to
   `Interface\AddOns\CinosCurse\`.
2. Restart the client (or `/reload`).
3. `/cc unlock` to drag the anchor where you want it, then `/cc lock`.
4. `/cc quick Curse of Agony` (or whatever you want on right-click).

## Compatibility

- Built and tested on **3.3.5a (build 12340)**.
- No Nampower / SuperWoW dependency.
- Works on retail-style WotLK private servers.

## License

MIT.
