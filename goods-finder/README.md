# Goods Finder v1.1.1

## What it does

**Goods Finder** gives you fast access to Anno 117's native province-wide goods view.

Press **Ctrl+Alt+G** from normal gameplay. You no longer need to open a warehouse first.

- If no valid product is hovered, Goods Finder opens the full native goods list.
- If you are in a warehouse and hover a valid good, that good is preselected when possible.
- You can use Anno's native **Latium / Albion** tabs while Goods Finder is open.
- After a province switch, Goods Finder automatically reopens the goods list in the selected province.

The mod uses Anno's own goods window rather than replacing it with a custom stock screen.

## Shortcut

Default: **Ctrl+Alt+G**

The Goods Finder shortcut is configurable in Anno 117 under **Settings -> Controls**. The permanent Goods Finder shortcut identity and command are preserved so future default-key changes do not silently replace the control entry.

## How to use

1. Press **Ctrl+Alt+G** from normal gameplay.
2. Browse or hover goods in the native goods list.
3. Use the native **Latium / Albion** tabs if you want to view the other province.
4. Goods Finder automatically reopens the goods list after the province switch.
5. Press **Escape** to leave.

Optional warehouse workflow:

1. Open a warehouse.
2. Hover a good.
3. Press **Ctrl+Alt+G**.
4. Goods Finder opens the same native goods list and preselects the hovered good when available.

## v1.1.1 highlights

- Added native configurable shortcut support in **Settings -> Controls**.
- Added localized Controls label: **Goods Finder - Open**.
- Default shortcut remains **Ctrl+Alt+G**.
- Preserved the existing shortcut command `GoodsFinder:CaptureOpenAndCreateRoute()`.
- Preserved the existing shortcut identifier `GoodsFinderProvinceStockMap`.
- No Goods Finder functional Lua behavior was changed in this controls maintenance release.

## v1.1.0 highlights

- **Ctrl+Alt+G works from normal gameplay**; a warehouse is no longer required.
- Warehouse hover remains available as optional good preselection.
- Added automatic **Latium / Albion** switching through Anno's native province tabs.
- Province switching reuses the same safe native goods doorway; no hard-coded player route is required.
- Added timing protection for the native province-tab transition.
- Added hardened cleanup for cases where Anno starts closing the Trade Route editor before Goods Finder's normal exit monitor runs.
- Added English, German and French mod metadata.
- Patch 2 compatible.

## Safety design

Goods Finder uses an existing trade route only as a temporary doorway into Anno's native goods list.

It will only use an **originally-empty usable Load Good row**. Existing occupied cargo instructions are not selected as the temporary doorway.

When the goods popup closes, Goods Finder attempts to remove its temporary doorway entry before leaving or before reopening after a province switch.

If Anno closes the Trade Route editor first, Goods Finder uses a guarded final cleanup path:

- only the row originally confirmed empty may be touched;
- cleanup runs at most once;
- Goods Finder does not issue a duplicate Trade Route close;
- Goods Finder does not use a delayed `PopUI`.

During v1.1.1 testing, the temporary native doorway could involve a ship that is not owned by the player. This is accepted behavior for this release. The safety criterion remains that existing occupied cargo instructions are protected and Goods Finder removes its own temporary selection.

## Browsing goods

Hovering goods is the safest intended browsing workflow.

If you click a good, Anno may temporarily configure that good on the helper row. Goods Finder calls the native `RemoveGood` cleanup before closing. Existing occupied cargo rows remain protected.

## Compatibility

- **Anno 117: Pax Romana**
- **Patch 2**
- Tested against build **2.0.1702353.294543**
- Existing savegames supported
- New game not required
- No dependency on Ship Finder, Rename Manager, or Specialist Management

## Languages

The mod name remains **Goods Finder** in all languages.

Public mod metadata and Controls labels are included in:

- English
- German
- French

The actual goods interface is Anno's native UI, so product names and native controls follow the language selected in the game.

## Installation

### Mod Browser

Install **Goods Finder** from the Anno 117 Mod Browser.

### Manual installation

Extract the `goods-finder` folder into one of Anno 117's mod folders, for example:

`<Documents>/Anno 117 - Pax Romana/mods/`

Remove older Goods Finder test builds first so that **Ctrl+Alt+G** is not registered more than once.

## Known requirements

Goods Finder needs at least one existing trade route that provides a safe, originally-empty usable Load Good row for the native doorway.

If no safe row can be found, Goods Finder stops instead of reusing an occupied cargo instruction.

## Author

Developed by **Dr. Enrico Handrick**  
GitHub: **SirLocksley13**
