# Goods Finder v1.0.0

## Plain-English summary

Hover over a product in a warehouse and press **Ctrl+Alt+G**. Goods Finder opens Anno 117's normal goods list, highlights the product, and shows how much is stored on every owned island in the current province.

You can hover other products to compare them. When you press **Escape**, Goods Finder removes its temporary trade-route entry and returns to the warehouse without changing existing cargo instructions.

## Features

- Opens from a warehouse with **Ctrl+Alt+G**.
- Automatically focuses the product under the mouse.
- Uses the vanilla province-wide island stock display.
- Keeps the goods list fully visible and interactive.
- Lets you hover or click other products while comparing stock.
- Protects all existing occupied cargo rows.
- Removes the temporary product entry before closing.
- Works with existing savegames.
- Requires no Ship Finder installation and has no other mod dependency.

## How to use

1. Open any warehouse.
2. Hover over the product you want to inspect.
3. Press **Ctrl+Alt+G**.
4. Hover other products to compare their province-wide stock.
5. Press **Escape once** to close Goods Finder and return to the warehouse.

## Safety

Goods Finder uses an existing trade route only as a doorway to Anno 117's vanilla goods window.

It accepts only a route that has:

- at least two stations;
- a station in the current province;
- an originally-empty usable **Load Good** row.

Occupied cargo instructions are never used. If no safe empty row is available, Goods Finder stops instead of changing an existing instruction.

## Intentional save question

If you make a real trade-route change while Goods Finder is open—such as adding or removing an island—the game will correctly ask whether you want to save that change.

This is intentional. Goods Finder automatically removes only its own temporary product entry; it does not silently undo deliberate route changes.

## Installation

### Mod Browser

Find **Goods Finder** in the Anno 117 Mod Browser and select **Install**.

### Manual installation

Extract the `goods-finder` folder into either:

- `<Documents>/Anno 117 - Pax Romana/mods/`
- `<Anno 117 installation folder>/mods/`

Remove older Goods Finder test builds before installing v1.0.0 to avoid duplicate **Ctrl+Alt+G** shortcuts.

## Compatibility

- Anno 117: Pax Romana
- Tested with game version **1.6.1.1680013**
- Existing savegames supported
- New game not required
- Current province only
- Safe to remove

## Known limitations

- At least one suitable existing trade route must be available in the current province.
- A safe originally-empty Load Good row must exist.
- Deliberate trade-route structure changes can trigger the normal save confirmation.
- The mod does not create temporary routes or click islands automatically.

## Author

**Developed by Dr. Enrico Handrick under the GitHub username SirLocksley13.**
