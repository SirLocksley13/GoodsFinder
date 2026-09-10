# Goods Finder for Anno 117

Goods Finder is a savegame-compatible quality-of-life mod for **Anno 117: Pax Romana**.

Press **Ctrl+Alt+G** from normal gameplay to open Anno 117's native goods list. If you hover a valid warehouse good first, Goods Finder preselects it when possible. You can also switch between Latium and Albion with the native province tabs while the goods list is open.

## Release

Current release: **v1.1.1**

The public mod source is located in `goods-finder/`.

The ready-to-upload Mod.io package is located in `release/GoodsFinder_v1.1.1.zip`.

## Highlights

- Opens from normal gameplay; warehouse-first workflow is optional
- Native configurable shortcut under **Settings -> Controls**
- Default shortcut **Ctrl+Alt+G**
- Optional hovered-good preselection
- Native Latium / Albion province switching with automatic goods-list reopen
- Safe originally-empty trade-route doorway row
- Automatic cleanup of temporary product selections
- Existing occupied cargo instructions remain protected
- Existing savegames supported; no new game required

## Important behavior

Goods Finder uses Anno's Trade Route UI only as a temporary doorway into the native goods list. During testing, the temporary doorway could involve a ship that is not owned by the player. This is currently treated as acceptable behavior; the safety requirement is that Goods Finder does not overwrite an occupied cargo instruction and cleans up its own temporary entry.

If the player makes a genuine route change, such as adding an island, Anno 117 correctly displays its normal **Save changes?** confirmation. Goods Finder does not silently undo deliberate route edits.

## Author

**Developed by Dr. Enrico Handrick under the GitHub username SirLocksley13.**
