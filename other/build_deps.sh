#!/bin/bash

MIN_NIX_VERSION="2.34.6"
BUILD_NIX=true
DEBUG_NIX=false

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

set -euo pipefail
scriptDir="$(get_script_dir)"
projDir=`realpath ${scriptDir}/..`
echo "Project root directory seems to be: $projDir"

if [[ "$BUILD_NIX" = true ]]; then
  nixExec=$(which nix)

  if [[ -z "$nixExec" ]]; then
    echo "ERROR: Could not find 'nix' command. Please ensure Nix $MIN_NIX_VERSION or higher is installed."
    exit 1
  fi

  if [[ ! -f $projDir/flake.nix ]]; then
    echo "ERROR: Could not find 'flake.nix' (expected location: $projDir/flake.nix)."
    echo "Please ensure it is present and this script is located in $projDir/other/"
    exit 1
  fi

  if [[ "$DEBUG_NIX" = true ]]; then
    $nixExec build --keep-failed --print-build-logs --verbose
  else
    $nixExec build --print-build-logs --verbose
  fi
fi

appContentsDir="$projDir/result/Applications/IINA.app/Contents"
srcLibDir="$appContentsDir/Frameworks"
dstLibDir="$projDir/deps/lib"
echo "📎 Replacing libs @ $dstLibDir …"
rm -rf "$dstLibDir"
mkdir -p "$dstLibDir"

for srclib in $(ls $srcLibDir)
do
  if [[ "$srclib" == *".dylib" ]]; then
    cp -v "$srcLibDir/$srclib" "$dstLibDir/"
  fi
done

srcExecutablesDir="$appContentsDir/MacOS"
dstExecutablesDir="$projDir/deps/executable"
echo "📎 Replacing executables @ $dstExecutablesDir …"
rm -rf "$dstExecutablesDir"
mkdir -p "$dstExecutablesDir"
for executable in $(ls $srcExecutablesDir)
do
  if [[ "$executable" != *"iina"* ]] && [[ "$executable" != *"IINA"* ]]; then
    cp -v "$srcExecutablesDir/$executable" "$dstExecutablesDir/"
  fi
done

# srcIncludeDir="$projDir/result/include"
# dstIncludeDir="$projDir/deps/include"
# echo "📎 Replacing include files @ $dstIncludeDir …"
# rm -rf "$dstIncludeDir"
# cp -vr "$srcIncludeDir" "$dstIncludeDir"

echo "✅ Done replacing deps/lib, deps/executable"

