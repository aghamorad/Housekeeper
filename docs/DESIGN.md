# Housekeeper — design truth

Surface mode: **Operate**. Scanability, speed and native clarity outrank
decoration. This is a utility used in a hurry, often while something is broken.

## Identity
- Signature colour: burgundy/oxblood (`HousekeepingPalette`), warm parchment text.
- Native macOS chrome: real sidebar, real title bar, system semantic colours for
  the window ground. No gradient backdrops, no glass panels.
- One mascot: the red octopus housekeeper, drawn from the single supplied icon.
- Type: system sans in modern mode, a restrained classic face in the retro theme.

## Rules
- One primary action per screen. Secondary controls are plain; navigation lives
  in the sidebar, not in an action row.
- Destructive actions are **filled red** (`ThemeButton(isDestructive: true)`),
  never the accent colour and never a grey button with red text.
- Reversible actions keep the accent fill and say so in one line.
- Cards group a thing; never nest a card in a card.
- Numbers use tabular figures. Counts never jitter.
- No emoji icons. SF Symbols only.
- Motion is event-driven, 150–300 ms, GPU properties only, and stops at idle.

## Learned taste rules
- **2026-11-24 — never reframe supplied artwork.** The supplied `AppIcon.icns`
  already contains its own liquid-glass squircle. Resampling it into a generated
  icon frame makes the art smaller inside a second box. Copy the file unchanged
  and verify the checksum.
- **2026-11-24 — button overload reads as distrust.** On Clean Up and Quarantine,
  reduce to the acts that matter: restore (accent) and delete (red). Move rare,
  irreversible bulk actions to a quiet text link, not a third filled button.
- **2026-11-24 — never touch a developer's signature.** Clearing a download flag
  is not "repairing" an app. A screen named Repair invited the app to rewrite
  signatures and broke Chrome. Favour the narrowest true operation, and say what
  it does not do.
