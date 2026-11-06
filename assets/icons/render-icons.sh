#!/bin/bash
# Export Finder and menu bar representations from the two original Dota item plates.
set -euo pipefail

icons_dir="$(cd "$(dirname "$0")" && pwd)"
panel_dir="$icons_dir/../panel"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Keep the bottle's aspect ratio. The central square retains its cork and glass
# silhouette; only the far edges of the rectangular inventory slot are trimmed.
render_square() {
    local artwork="$1" edge="$2" radius="$3" destination="$4"
    local last=$((edge - 1))
    magick "$artwork" -gravity center -crop 64x64+0+0 +repage \
        -filter Lanczos -resize "${edge}x${edge}" \
        \( -size "${edge}x${edge}" xc:none -fill white \
           -draw "roundrectangle 0,0 $last,$last $radius,$radius" \) \
        -compose DstIn -composite -strip PNG32:"$destination"
}

render_square "$panel_dir/bottle.png" 832 178 "$scratch/icon-body.png"
magick "$scratch/icon-body.png" -gravity center -background none \
    -extent 1024x1024 -strip PNG32:"$icons_dir/icon.png"
mkdir -p "$icons_dir/icon.iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=""
        if [ "$scale" = 2 ]; then suffix="@2x"; fi
        magick "$icons_dir/icon.png" -filter Lanczos -resize "${pixels}x${pixels}" \
            -strip PNG32:"$icons_dir/icon.iconset/icon_${size}x${size}${suffix}.png"
    done
done
iconutil -c icns "$icons_dir/icon.iconset" -o "$icons_dir/icon.icns"

# A question mark distinguishes unknown inventory even without color. Render
# at six times the display size before downsampling for the two display scales.
render_square "$panel_dir/bottle-empty.png" 108 18 "$scratch/unknown.png"
question="stroke-linecap round path 'M33,35 C35,15 74,16 75,37 C76,48 68,53 61,57 C56,60 53,63 53,68'"
magick "$scratch/unknown.png" -modulate 48,0,100 -fill none \
    -stroke '#182027' -strokewidth 17 -draw "$question" \
    -stroke white -strokewidth 11 -draw "$question" \
    -stroke '#182027' -strokewidth 4 -fill white -draw 'circle 53,85 53,92' \
    -strip PNG32:"$scratch/marked.png"

for scale in 1 2; do
    pixels=$((18 * scale))
    suffix=""
    if [ "$scale" = 2 ]; then suffix="@2x"; fi
    render_square "$panel_dir/bottle.png" "$pixels" "$((3 * scale))" "$icons_dir/trayStored${suffix}.png"
    render_square "$panel_dir/bottle-empty.png" "$pixels" "$((3 * scale))" "$icons_dir/trayEmpty${suffix}.png"
    magick "$scratch/marked.png" -filter Lanczos -resize "${pixels}x${pixels}" \
        -strip PNG32:"$icons_dir/trayUnknown${suffix}.png"
done
