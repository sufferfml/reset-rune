# Application and menu bar icons

Finder uses the Dota 2 bottled regeneration rune inventory plate. The menu bar uses color impressions of the stored or empty bottle, plus a marked empty bottle for unconfirmed inventory. The source images and usage details are listed in [Artwork and sources](../ARTWORK.md).

- `icon.png`, `icon.iconset/` and `icon.icns` contain the application icon and macOS representations.
- `trayStored`, `trayEmpty` and `trayUnknown` ship at 18 px and 36 px for 1× and 2× rendering. Their RGB colors and corner transparency should be preserved when creating the status item.
- `render-icons.sh` creates the exports from the original PNGs in `assets/panel`. It requires ImageMagick 7 and macOS `iconutil`.

Regenerate from the project root with `assets/icons/render-icons.sh`.
