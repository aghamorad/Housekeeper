# Housekeeper — design truth

Surface mode: **Operate**. Scanability, speed and native clarity outrank
decoration. This is a utility used in a hurry, often while something is broken.

## Identity
- Signature colour: refined oxblood/burgundy (`HousekeepingPalette`), luminous warm
  alabaster in Light Mode, deep obsidian-merlot in Dark Mode.
- Native macOS 26/27 Liquid Glass ("Golden Gate") chrome: translucent `.sidebar`
  vibrancy behind a full-size transparent titlebar, floating `GlassEffectContainer`
  toolbar capsules, interactive `.glassEffect` navigation/action/hero surfaces, and
  crisp low-noise translucent content surfaces (never heavy blur on 100 scrolling
  list rows — `0.0%` idle CPU and lean RAM).
- One mascot: the red octopus housekeeper, drawn from the single supplied icon.
- Type: system sans/rounded in Liquid Glass mode, a restrained classic face in
  Classic 9 mode.

## Rules
- One primary action per screen. Secondary controls are frosted glass capsules;
  navigation lives in the sidebar, not in a 3-row action bar.
- Destructive actions are **filled crimson glass** (`ThemeButton(isDestructive: true)`),
  never the accent colour and never a grey button with red text.
- Simple by default: cleaning and uninstalling go straight to macOS Trash unless
  the user opts into Quarantine Safety Net (offered once on first launch, toggleable
  in Settings).
- Cards group a thing; never nest a card in a card.
- Numbers use tabular figures. Counts never jitter.
- No emoji icons. SF Symbols only.
- Motion is event-driven, 150–300 ms, GPU properties only, and stops at idle (`0.0%` CPU).

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
