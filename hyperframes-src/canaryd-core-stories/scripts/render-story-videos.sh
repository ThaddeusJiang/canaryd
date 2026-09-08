#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

input="output/publish/canaryd-core-stories.mp4"
output_root="output/publish/stories"

ffmpeg -version | grep -q '^ffmpeg version 8\.1 '
test -f "$input"

render_story() {
  slug="$1"
  start="$2"
  duration="$3"
  output_dir="$output_root/$slug"
  mp4="$output_dir/$slug.mp4"
  gif="$output_dir/$slug.gif"

  mkdir -p "$output_dir"

  ffmpeg -hide_banner -loglevel error -y \
    -ss "$start" \
    -t "$duration" \
    -i "$input" \
    -an \
    -c:v libx264 \
    -preset slow \
    -crf 18 \
    -pix_fmt yuv420p \
    -movflags +faststart \
    "$mp4"

  ffmpeg -hide_banner -loglevel error -y \
    -i "$mp4" \
    -filter_complex \
      "fps=10,scale=860:-2:flags=lanczos,split[palette_source][gif_source];[palette_source]palettegen=max_colors=128:stats_mode=diff[palette];[gif_source][palette]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 \
    "$gif"
}

render_story "cursoruiviewservice-recovery" "0" "3.88"
render_story "idle-simulators" "3.95" "2.68"
render_story "cleanclip-functional-probe" "6.7" "2.68"
render_story "thermal-pressure" "9.45" "2.68"
render_story "idle-memory-recovery" "12.2" "2.68"
render_story "stale-build-cleanup" "14.95" "2.68"
