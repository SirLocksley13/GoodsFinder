# Mod.io Upload Text

## Name

Goods Finder

## URL name / slug

goods-finder

## Summary

Open the vanilla goods list from a warehouse, focus the hovered product, and compare its stock across all owned islands in the current province. Shortcut: Ctrl+Alt+G.

## Version

1.0.0

## Changelog

Initial public release. Adds Ctrl+Alt+G warehouse product lookup, province-wide island stock, a fully interactive vanilla goods list, safe empty-row route access, and automatic cleanup of temporary product selections.

## Description

### About

Goods Finder makes it easy to check where a product is stored across your current province.

Open a warehouse, hover the product you want to inspect, and press **Ctrl+Alt+G**. Goods Finder opens Anno 117's normal goods list, focuses the selected product, and displays its stock on every owned island in the current province.

You can freely hover other products to compare their island stock.

### Features

- Province-wide island stock from any warehouse
- Automatic focus of the hovered warehouse product
- Fully visible and interactive vanilla goods list
- Compare other products by hovering or clicking them
- Existing cargo instructions remain protected
- Temporary product selections are removed automatically
- Repeated use in the same session is supported
- Existing savegames supported
- No new game required
- No dependency on Ship Finder or another mod

### Shortcut

**Ctrl+Alt+G**

### How it works safely

Goods Finder opens the vanilla goods window through a suitable existing trade route in the current province.

It uses only a Load Good row that was originally empty. Occupied cargo instructions are never used. When Goods Finder closes, its temporary product entry is removed before the Trade Route editor closes.

If no safe empty row is available, the workflow stops rather than changing existing cargo.

### Important: real route changes

If you make a genuine trade-route change while Goods Finder is open—for example, adding or removing an island—Anno 117 will correctly show the normal **Save changes?** question.

This is intentional. Goods Finder removes only its own temporary product entry and does not silently undo deliberate route edits.

### Requirements

- An existing trade route with at least two stations
- A suitable station in the current province
- An originally-empty usable Load Good row

### Compatibility

- Tested with Anno 117 version 1.6.1.1680013
- Existing savegames supported
- New game not required
- Current province only
- Safe to remove

### Author

**Developed by Dr. Enrico Handrick under the GitHub username SirLocksley13.**
