#!/bin/bash

BUILD_NIX=false
DEBUG=true

LIBS=(
  "libarchive.13.dylib" "libass.9.dylib" "libavcodec.62.dylib" "libavdevice.62.dylib" "libavfilter.11.dylib"
  "libavformat.62.dylib" "libavutil.60.dylib" "libb2.1.dylib" "libbluray.2.dylib" "libbrotlicommon.1.dylib"
  "libbrotlidec.1.dylib" "libbrotlienc.1.dylib" "libdav1d.7.dylib" "libfontconfig.1.dylib" "libfreetype.6.dylib"
  "libfribidi.0.dylib" "libglib-2.0.0.dylib" "libgmp.10.dylib" "libgnutls.30.dylib" "libgraphite2.3.dylib"
  "libharfbuzz.0.dylib" "libhogweed.6.dylib" "libhwy.1.dylib" "libidn2.0.dylib" "libintl.8.dylib"
  "libjpeg.62.dylib" "libjxl_cms.0.11.dylib" "libjxl_threads.0.11.dylib" "libjxl.0.11.dylib" "liblcms2.2.dylib"
  "libluajit-5.1.2.dylib" "liblz4.1.dylib" "liblzma.5.dylib" "libmpv.2.dylib" "libmujs.dylib"
  "libnettle.8.dylib" "libp11-kit.0.dylib" "libpcre2-8.0.dylib" "libplacebo.351.dylib" "libpng16.16.dylib"
  "librubberband.3.dylib" "libsamplerate.0.dylib" "libshaderc_shared.1.dylib" "libsharpyuv.0.dylib" "libsnappy.1.dylib"
  "libsodium.26.dylib" "libsoxr.0.dylib" "libspeex.1.dylib" "libswresample.6.dylib" "libswscale.9.dylib"
  "libtasn1.6.dylib" "libuchardet.0.dylib" "libunibreak.6.dylib" "libunistring.5.dylib" "libvidstab.1.2.dylib"
  "libvulkan.1.dylib" "libwebp.7.dylib" "libwebpmux.3.dylib" "libX11.6.dylib" "libXau.6.dylib"
  "libxcb-shape.0.dylib" "libxcb-shm.0.dylib" "libxcb-xfixes.0.dylib" "libxcb.1.dylib" "libXdmcp.6.dylib"
  "libz.dylib" "libzimg.2.dylib" "libzmq.5.dylib" "libzstd.1.5.7.dylib"
)

get_script_dir()
{
    local SOURCE_PATH="${BASH_SOURCE[0]}"
    local SYMLINK_DIR
    local SCRIPT_DIR
    # Resolve symlinks recursively
    while [ -L "$SOURCE_PATH" ]; do
        # Get symlink directory
        SYMLINK_DIR="$( cd -P "$( dirname "$SOURCE_PATH" )" >/dev/null 2>&1 && pwd )"
        # Resolve symlink target (relative or absolute)
        SOURCE_PATH="$(readlink "$SOURCE_PATH")"
        # Check if candidate path is relative or absolute
        if [[ $SOURCE_PATH != /* ]]; then
            # Candidate path is relative, resolve to full path
            SOURCE_PATH=$SYMLINK_DIR/$SOURCE_PATH
        fi
    done
    # Get final script directory path from fully resolved source path
    SCRIPT_DIR="$(cd -P "$( dirname "$SOURCE_PATH" )" >/dev/null 2>&1 && pwd)"
    echo "$SCRIPT_DIR"
}

scriptDir="$(get_script_dir)"
echo "Script dir: $scriptDir"

set -euo pipefail

projDir="$scriptDir/.."
cd "$scriptDir/.."
echo "Project root directory: $projDir"

if [[ "$BUILD_NIX" = true ]]; then
  nixExec=$(which nix)

  if [[ -z "$nixExec" ]]; then
    echo "Could not find 'nix' executable. Please ensure Nix is installed."
    exit 1
  fi

  if [[ ! -f $projDir/flake.nix ]]; then
    echo "Could not find flake.nix in project root directory."
    echo "Please ensure it is present and this script is located in {project_root}/other/"
    exit 1
  fi

  if [[ "$DEBUG" = true ]]; then
    $nixExec build --keep-failed --print-build-logs --verbose
  else
    $nixExec build
  fi
fi

echo "📎 Replacing deps/lib..."
appContentsDir="$projDir/result/Applications/IINA.app/Contents"
srcLibDir="$appContentsDir/Frameworks"
dstLibDir="$projDir/deps/lib"
rm -rf "$dstLibDir"
mkdir -p "$dstLibDir"

for libName in "${LIBS[@]}"
do
  srcLibPath="$srcLibDir/$libName"
  cp -v "$srcLibPath" "$dstLibDir/"
done

echo "📎 Replacing deps/executable..."
srcExecutablesDir="$appContentsDir/MacOS"
dstExecutablesDir="$projDir/deps/executable"
rm -rf "$dstExecutablesDir"
mkdir -p "$dstExecutablesDir"
for executable in $(ls $srcExecutablesDir)
do
  if [[ "$executable" != *"iina"* ]] && [[ "$executable" != *"IINA"* ]]; then
    cp -v "$srcExecutablesDir/$executable" "$dstExecutablesDir/"
  fi
done

echo "✅ Done replacing deps/lib & deps/executable"

