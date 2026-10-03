# Sourced by audio model checks. Match the app's mpv-before-VLC dependency order.
mpv_products="${GENPLAYER_MPV_PRODUCTS_DIR:-$framework_dir}"
if [[ ! -d "$mpv_products/Libmpv.framework" || ! -f "$mpv_products/libMoltenVK.a" ]]; then
    echo 'Set GENPLAYER_MPV_PRODUCTS_DIR to the completed macOS Build/Products/Debug directory.' >&2
    exit 1
fi
mpv_flags=(-F "$mpv_products" -L "$mpv_products" -lMoltenVK -lc++ -lz -lbz2 -liconv -lexpat -lresolv -lxml2)
for mpv_framework in "$mpv_products"/*.framework; do
    mpv_name="$(basename "$mpv_framework" .framework)"
    if [[ "$mpv_name" != VLCKit ]]; then mpv_flags+=(-framework "$mpv_name"); fi
done
for mpv_name in AppKit AVFoundation CoreAudio AudioToolbox CoreVideo CoreMedia VideoToolbox Metal QuartzCore OpenGL IOKit Security CoreServices; do
    mpv_flags+=(-framework "$mpv_name")
done
