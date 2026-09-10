# Publishing Checklist

## Final files

- `release/GoodsFinder_v1.1.1.zip` — upload as the mod file
- `media/GoodsFinder_Modio_Logo_1280x720.png` — main Mod.io logo
- `media/GoodsFinder_How_To_Use_1280x720.png` — optional gallery image
- `docs/MODIO_UPLOAD_TEXT.md` — copy the current profile fields and description
- `CHANGELOG.md` — GitHub and release notes
- `CHECKSUMS.txt` — verify files before uploading

## Before uploading

1. Remove every older Goods Finder test/candidate build from the Anno mods folder.
2. Install only `GoodsFinder_v1.1.1.zip`.
3. Confirm `modinfo.json` reports version `1.1.1` and Goods Finder loads normally.
4. In **Settings -> Controls**, confirm the label **Goods Finder - Open** and default **Ctrl+Alt+G**.
5. Remap the shortcut and confirm the remapped key opens Goods Finder and Ctrl+Alt+G no longer does.
6. Restart Anno and confirm the remap persists; Reset to Default must restore Ctrl+Alt+G.
7. Test opening from normal gameplay with no hovered product.
8. Test warehouse-hover preselection.
9. Test Latium -> Albion -> Latium and automatic goods-list reopen.
10. Browse/click a good, close normally, and confirm no occupied trade-route cargo instruction changed and no unwanted temporary good remains.
11. Repeat open/close several times.
12. If a temporary doorway uses a ship not owned by the player, treat that as acceptable provided the cargo-row safety checks above remain clean.
13. Upload the exact final ZIP without repacking it.
