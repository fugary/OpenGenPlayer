#!/bin/sh

set -eu

ICON_ROOT="${SRCROOT}/GenPlayer/Assets.xcassets"
APP_BUNDLE="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"

render_icon() {
  source_png="$1"
  pixel_size="$2"
  output_png="$3"

  if [ ! -f "$source_png" ]; then
    return 0
  fi

  sips -s format png -z "$pixel_size" "$pixel_size" "$source_png" --out "$output_png" >/dev/null
}

render_icon_scales() {
  source_png="$1"
  suffix="${2:-}"

  render_icon "$source_png" 20 "${set_dir}/icon_20@1x${suffix}.png"
  render_icon "$source_png" 40 "${set_dir}/icon_20@2x${suffix}.png"
  render_icon "$source_png" 60 "${set_dir}/icon_20@3x${suffix}.png"
  render_icon "$source_png" 29 "${set_dir}/icon_29@1x${suffix}.png"
  render_icon "$source_png" 58 "${set_dir}/icon_29@2x${suffix}.png"
  render_icon "$source_png" 87 "${set_dir}/icon_29@3x${suffix}.png"
  render_icon "$source_png" 40 "${set_dir}/icon_40@1x${suffix}.png"
  render_icon "$source_png" 80 "${set_dir}/icon_40@2x${suffix}.png"
  render_icon "$source_png" 120 "${set_dir}/icon_40@3x${suffix}.png"
  render_icon "$source_png" 120 "${set_dir}/icon_60@2x${suffix}.png"
  render_icon "$source_png" 180 "${set_dir}/icon_60@3x${suffix}.png"
  render_icon "$source_png" 76 "${set_dir}/icon_76@1x${suffix}.png"
  render_icon "$source_png" 152 "${set_dir}/icon_76@2x${suffix}.png"
  render_icon "$source_png" 167 "${set_dir}/icon_83.5@2x${suffix}.png"
}

prepare_icon_set() {
  icon_name="$1"
  set_dir="${ICON_ROOT}/${icon_name}.appiconset"
  source_png="${set_dir}/1024.png"
  dark_png="${set_dir}/1024-dark.png"

  if [ -f "$source_png" ]; then
    render_icon_scales "$source_png" ""
  fi

  if [ -f "$dark_png" ]; then
    render_icon_scales "$dark_png" "-dark"
  fi
}

copy_icon() {
  source_png="$1"
  bundle_name="$2"

  if [ -f "$source_png" ]; then
    cp -f "$source_png" "${APP_BUNDLE}/${bundle_name}"
  fi
}

copy_alternate_icon_bundle_files() {
  icon_name="$1"
  set_dir="${ICON_ROOT}/${icon_name}.appiconset"

  copy_icon "${set_dir}/icon_60@2x.png" "${icon_name}60x60@2x.png"
  copy_icon "${set_dir}/icon_60@3x.png" "${icon_name}60x60@3x.png"
  copy_icon "${set_dir}/icon_76@2x.png" "${icon_name}76x76@2x~ipad.png"
}

mkdir -p "${APP_BUNDLE}"

ALTERNATE_ICON_NAMES="AppIconClassic AppIconSlate AppIconVortex AppIconCoral AppIconAcrylic AppIconNeon AppIconEco AppIconElectricCoral AppIconGoldenGlossy AppIconPlatinum AppIconRoseGold AppIconRoyalEmerald AppIconSunset AppIconDarkAurora AppIconObsidianWhite AppIconMidnightGold AppIconIvoryGold"
ALL_ICON_NAMES="${ALTERNATE_ICON_NAMES}"

for icon_name in ${ALL_ICON_NAMES}; do
  prepare_icon_set "${icon_name}"
done

for icon_name in ${ALTERNATE_ICON_NAMES}; do
  copy_alternate_icon_bundle_files "${icon_name}"
done
