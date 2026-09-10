# Changelog

## 1.1.1 — 2026-09-09

Patch 2 controls maintenance release.

- Added native configurable shortcut support under **Settings -> Controls**.
- Added localized Controls labels in English, German and French.
- Kept the default shortcut at **Ctrl+Alt+G**.
- Preserved the permanent shortcut command `GoodsFinder:CaptureOpenAndCreateRoute()`.
- Preserved the permanent shortcut identifier `GoodsFinderProvinceStockMap`.
- Added the proven Patch 2 shortcut flags `Configurable`, `HideInOptionMenu` and `AllowMultipleShortcuts`.
- Preserved the v1.1.0 Goods Finder functional Lua behavior.
- Recorded that the temporary native route doorway may involve a ship not owned by the player; this is accepted as long as existing occupied cargo instructions remain protected and the temporary selection is cleaned up.

## 1.1.0 — 2026-08-23

Normal-gameplay and province-switching release.

- Ctrl+Alt+G can open Goods Finder directly from normal gameplay; a warehouse is no longer required.
- Warehouse hover remains available as optional product preselection.
- Added automatic Latium / Albion switching through Anno's native province tabs.
- Added automatic goods-list reopen after a province switch.
- Added timing protection around native province transitions.
- Hardened cleanup if Anno begins closing the Trade Route editor before the normal Goods Finder exit monitor runs.
- Added English, German and French mod metadata.
- Updated for Anno 117 Patch 2.

## 1.0.0 — 2026-07-25

Initial public release.

- Added Ctrl+Alt+G warehouse shortcut.
- Added automatic product detection from the warehouse infotip.
- Added current-province island stock display through the vanilla goods list.
- Added automatic focus of the remembered product.
- Preserved free hovering and product comparison.
- Added safe existing-route selection.
- Added originally-empty Load Good row requirement.
- Added automatic removal of temporary product selections.
- Protected occupied cargo instructions.
- Added repeated-use cleanup reset.
- Added safe abort when no suitable empty row exists.
- Confirmed expected Save changes behavior after genuine route edits.
