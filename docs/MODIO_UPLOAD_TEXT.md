# Mod.io Upload Text

## Name

Goods Finder

## URL name / slug

goods-finder

## Summary

Open Anno 117's native goods list directly from normal gameplay, compare stock across your islands, optionally preselect a hovered warehouse good, and switch between Latium and Albion. Default shortcut: Ctrl+Alt+G.

## Version

1.1.1

## Changelog

Patch 2 controls maintenance release. Adds native configurable Controls support and localized shortcut labels while preserving the existing Ctrl+Alt+G default, permanent shortcut identity, and v1.1.0 Goods Finder behavior.

## Description

### About

Goods Finder gives you quick access to Anno 117's native province-wide goods view.

Press **Ctrl+Alt+G** directly from normal gameplay. If no valid product is hovered, Goods Finder opens the full goods list. If you first hover a valid good in a warehouse, Goods Finder preselects it when possible.

You can use Anno's native **Latium / Albion** tabs while Goods Finder is open. After switching province, Goods Finder automatically reopens the goods list in the selected province.

### Features

- Opens directly from normal gameplay
- Optional hovered warehouse-good preselection
- Fully visible and interactive native goods list
- Native Latium / Albion province switching
- Automatic goods-list reopen after province switching
- Configurable shortcut under **Settings -> Controls**
- Default shortcut **Ctrl+Alt+G**
- Existing occupied cargo instructions remain protected
- Temporary product selections are removed automatically
- Repeated use in the same session is supported
- Existing savegames supported
- No new game required
- No dependency on Ship Finder, Rename Manager or Specialist Management

### Shortcut

Default: **Ctrl+Alt+G**

The shortcut can be changed in Anno 117 under **Settings -> Controls**. Reset to Default restores Ctrl+Alt+G.

### How it works safely

Goods Finder opens the native goods window through a suitable existing trade route.

It uses only a Load Good row that was originally empty. Occupied cargo instructions are not selected as the temporary doorway. When the goods popup closes, Goods Finder removes its own temporary product entry before leaving or reopening after a province switch.

During testing, the temporary native doorway could involve a ship that is not owned by the player. This is accepted behavior for this release; the safety requirement is that existing occupied cargo instructions are not overwritten and the temporary Goods Finder selection is cleaned up.

If no safe empty row can be found, Goods Finder stops instead of reusing an occupied cargo instruction.

### Important: real route changes

If you make a genuine trade-route change while Goods Finder is open—for example, adding or removing an island—Anno 117 will correctly show its normal **Save changes?** question.

This is intentional. Goods Finder removes only its own temporary product entry and does not silently undo deliberate route edits.

### Compatibility

- Anno 117: Pax Romana
- Patch 2
- Tested against build **2.0.1702353.294543**
- Existing savegames supported
- New game not required
- Safe to remove

### Author

**Developed by Dr. Enrico Handrick under the GitHub username SirLocksley13.**
