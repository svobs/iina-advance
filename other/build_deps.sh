#!/bin/bash

BUILD_NIX=false
DEBUG=true

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

for srclib in $(ls $srcLibDir)
do
  if [[ "$srclib" == *".dylib" ]]; then
    cp -v "$srcLibDir/$srclib" "$dstLibDir/"
  fi
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

