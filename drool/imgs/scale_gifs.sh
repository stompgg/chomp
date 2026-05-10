#!/bin/bash

for f in *_damage.gif; do
  [ -f "$f" ] || continue
  filename="${f%.gif}"
  magick "$f" \
    -filter point \
    -interpolate nearest \
    -resize 400% \
    "${filename}_4x.gif"
  echo "Scaled: $f → ${filename}_4x.gif"
done
