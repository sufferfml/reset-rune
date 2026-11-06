# App and menu bar icons

Original artwork for Bottled Reset Rune. No Valve artwork or logos are included.

- `icon.png`, `icon.icns`, `icon.iconset/`: application icon and macOS representations.
- `icon-empty.png`: matching empty-bottle artwork.
- `trayTemplate*`: monochrome bottle with stored rune.
- `trayEmptyTemplate*`: empty bottle outline.
- `trayUnknownTemplate*`: bottle with a dash for unconfirmed inventory.
- `render-tray.swift`: AppKit source for the 18-point menu bar templates at 1× and 2×.

The app icon remains fixed; menu bar templates reflect inventory. macOS supplies their foreground color.

Regenerate menu bar PNGs from the project root:

```sh
swift assets/icons/render-tray.swift "$PWD/assets/icons"
```

Panel artwork is documented in [assets/panel](../panel/README.md).
