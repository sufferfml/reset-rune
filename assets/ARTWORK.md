# Artwork and sources

Bottled Reset Rune uses Dota 2 inventory artwork for the bottle and interface details from Valve’s Dota 2 website. Copyright in this material belongs to Valve and its licensors. The repository’s MIT license covers the project code and the custom Reset Rune illustration.

## Valve assets

The two inventory plates in the repository preserve the original downloaded PNG bytes, including their painted backgrounds and landscape proportions.

| Local asset | Original | SHA-256 of the downloaded original |
| --- | --- | --- |
| [Stored rune bottle](panel/bottle.png) | [Bottle with Regeneration Rune, 88 × 64 PNG](https://cdn.akamai.steamstatic.com/apps/dota2/images/dota_react/items/bottle_regeneration.png) | `8e22cfb9ea33b3679dd39bb313a876de1051300b1bb5ecd189e82cf5769f5e66` |
| [Empty bottle](panel/bottle-empty.png) | [Empty Bottle, 88 × 64 PNG](https://cdn.akamai.steamstatic.com/apps/dota2/images/dota_react/items/bottle_empty.png) | `e7864971b5cdfc01728cd34ef9c6ff46b9fa342414714f77b46f068ae86f39ce` |
| [Panel texture](panel/dota-texture.jpg) | [Dota 2 website background, 1600 × 5184 JPEG](https://cdn.akamai.steamstatic.com/apps/dota2/images/dota_react/blog/bg_repeater.jpg) | `8c7765af394646893ef7985502c32ccee49638d5a329d944486f8a96aaa80a22` |
| [Panel divider](panel/dota-divider.png) | [Dota 2 website divider, 770 × 12 SVG](https://cdn.akamai.steamstatic.com/apps/dota2/images/dota_react/global/divider-line-point.svg) | `e9b982534380a9452d98ef26ba778d0e1d77e05724c195119ee21fc0ac3bc084` |
| [Successful redemption](panel/dota-success.png) | [The International 10 win checkmark, 79 × 76 PNG](https://cdn.akamai.steamstatic.com/apps/dota2/images/dota_react/international2020/icon_check.png) | `ff4593e45ba7978b51a428eca15d65f0db79147238f5e4187a63531f05f956b9` |

Finder and menu bar images are local exports of the two inventory plates. They retain the source artwork with a centered square crop, rounded corners and platform-specific sizes. The unknown-inventory menu image dims the empty plate and adds a question mark. [Offline export script](icons/render-icons.sh).

The texture uses the central 768 × 384 pixels of the original, downsampled to 384 × 192 and JPEG encoded at quality 83. The divider is rendered from the [original SVG](source/divider-line-point.svg) at its native dimensions using `sips -s format png`. The application ships the small local exports.

The allowance bar uses the left-to-right mana fill from Valve’s [hero page](https://www.dota2.com/hero/crystalmaiden), from `#1056DB` to `#73F5FE`. The [website stylesheet](https://www.dota2.com/public/css/dota_react/main.css?v=A9lGFvtEfXJh&l=english&_cdn=fastly) defines that gradient in `._1aQk6qbzk9zHJ78eUNwzw1`.

## Project artwork

[Reset Rune](panel/reset-rune.png) is the custom 256 × 256 RGBA item illustration shown in expanded inventory. Its design and generation prompt are recorded in the [art brief](panel/reset-rune-prompt.txt). SHA-256 is `f66d00da3285028a55d11cdb000f591bc5ed59f3950d5099b90faa361c462072`.
