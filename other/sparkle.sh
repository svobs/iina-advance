#!/bin/bash

# Run this script to publish a new release to the Sparkle appcast directory.
# 0. `cd` to the directory containing this script before running.
# 1. Make sure Sparkle exists inside this directory also (see SPARKLE_HOME below).
# 2. This script will compress the latest version of the app, generate deltas, place
#    it inside the appcast directory, and write a new version of appcast.xml.
# 3. After script completes, upload new/updated files to AWS update server.

if [ "$#" -ne 2 ]; then
  echo "Usage: ./sparkle.sh newVersion_appPath newVersionNumber"
  echo "Example: ./sparkle.sh \"./IINA Advance.app\" \"1.4.3\""
  exit 1
fi

## Script params ##

# Full path to the latest version, uncompressed (*.app)
NEW_VERSION_APP_PATH="$1"
# Latest marketing version (e.g., "1.4.3"
NEW_VERSION="$2"

MAX_VERSIONS=10

print_script_dir() {
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

SCRIPT_PATH="$(print_script_dir)"
SPARKLE_HOME="$(realpath ${SCRIPT_PATH}/Sparkle-2.6.4)"

# This is the Sparkle Appcast director
# 1. May already contain files (backup before running!):
#   - Binaries for some previosus versions ("IINA-Advance-${VER}.zip")
#   - Release notes for those versions ("IINA-Advance-${VER}.html")
#   - appcast.xml (but will be overwritten by this script!)
#   - Delta updates ("IINA-Advance-{N}-{M}.delta")
# 2. Prior to running this script, place the .html for the latest version in this dir
#    (should be named "IINA-Advance-${NEW_VERSION}.html").
APPCAST_DIR="$(realpath ${SCRIPT_PATH}/AppCast)"

ZIP_PATH="$APPCAST_DIR/IINA-Advance-$NEW_VERSION.zip"

# Creates Mac-friendly zip archive
ditto -c -k --sequesterRsrc --keepParent "$NEW_VERSION_APP_PATH" "$ZIP_PATH"

"$SPARKLE_HOME/bin/generate_appcast" --maximum-versions $MAX_VERSIONS \
		--maximum-deltas $MAX_VERSIONS \
		"$APPCAST_DIR"
