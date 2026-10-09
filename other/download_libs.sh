#!/bin/bash

SKIP_LIBS=false
SKIP_EXECUTABLES=false
SKIP_PLUGINS=false

DEPS_DOWNLOAD_PATH="https://github.com/svobs/iina-advance/releases/download/v1.6.1/iinaa-deps-1.7.zip"
DEPS_IS_APP=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

printUsageHelp() {
  echo
  echo -e "${BLUE}Usage:${NC}"
  echo -e "    ${GREEN}$0 [-h|--help]:${NC}           Displays this help message"
  echo -e "    ${GREEN}$0 [--skip-libs]:${NC}         Skip downloading dylibs"
  echo -e "    ${GREEN}$0 [--skip-executables]:${NC}  Skip downloading executables (youtube-dl)"
  echo -e "    ${GREEN}$0 [--skip-plugins]:${NC}      Skip downloading official plugins"
  echo
}

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

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    printUsageHelp
    exit 0
    ;;
  --skip-executables)
    SKIP_EXECUTABLES=true
    shift
    ;;
  --skip-libs)
    SKIP_LIBS=true
    shift
    ;;
  --skip-plugins)
    SKIP_PLUGINS=true
    shift
    ;;
  --)
    shift
    break
    ;;
  -*)
    echo -e "${RED}Unknown option: $1${NC}" >&2
    printUsageHelp
    exit 1
    ;;
  *)
    echo -e "${RED}Unexpected argument: $1${NC}" >&2
    printUsageHelp
    exit 1
    ;;
  esac
done
if [[ $# -gt 0 ]]; then
  echo -e "${RED}Unexpected argument: $1${NC}" >&2
  printUsageHelp
  exit 1
fi

SCRIPT_PATH="$(print_script_dir)"
PROJ_ROOT_PATH="$(realpath ${SCRIPT_PATH}/..)"
echo "Project root directory seems to be: $PROJ_ROOT_PATH"

DEPS_PATH="$PROJ_ROOT_PATH/deps"
LIB_PATH="$DEPS_PATH/lib"
EXEC_PATH="$DEPS_PATH/executable"
PLUGIN_PATH="$DEPS_PATH/plugins"

export DEPS_DOWNLOAD_PATH
export LIB_PATH
export YELLOW
export GREEN
export NC

if [[ ! -d "$DEPS_PATH" ]]; then
  echo -e "${RED}Unable to find the 'deps' directory inside '$PROJ_ROOT_PATH'${NC}" >&2
  exit 1
fi

ARCHIVE_NAME=$(basename "$DEPS_DOWNLOAD_PATH")

if [[ "$DEPS_IS_APP" == true ]]; then
  EXTRACTED_DIR_PATH="$DEPS_PATH/IINA Advance.app"
else
  EXTRACTED_DIR_PATH="$DEPS_PATH/${ARCHIVE_NAME%.zip}"
fi
rm -rf "$EXTRACTED_DIR_PATH"

curl -L -o "${DEPS_PATH}/${ARCHIVE_NAME}" "${DEPS_DOWNLOAD_PATH}" && echo -e "${GREEN}Downloaded ${ARCHIVE_NAME}${NC}"
# Use -o to overwrite existing files without prompting
if [[ "$DEPS_IS_APP" == true ]]; then
  unzip "${DEPS_PATH}/${ARCHIVE_NAME}" -d "$DEPS_PATH" -x "__MACOSX/*" && echo -e "${GREEN}Extracted ${ARCHIVE_NAME}${NC}"
else
  unzip "${DEPS_PATH}/${ARCHIVE_NAME}" -d "$DEPS_PATH" && echo -e "${GREEN}Extracted ${ARCHIVE_NAME}${NC}"
fi

if [[ "$SKIP_LIBS" == true ]]; then
  echo -e "${YELLOW}Skipping lib downloads.${NC}"
else
  rm -rf "$LIB_PATH"

  if [[ "$DEPS_IS_APP" == true ]]; then
    rm -r "$EXTRACTED_DIR_PATH/Contents/Frameworks/Sparkle.framework"
    mv "$EXTRACTED_DIR_PATH/Contents/Frameworks" "$LIB_PATH" && echo -e "${GREEN}Moved dylibs to $LIB_PATH${NC}"
  else
    mv "$EXTRACTED_DIR_PATH/lib" "$LIB_PATH" && echo -e "${GREEN}Moved dylibs to $LIB_PATH${NC}"
  fi

fi

if [[ "$SKIP_EXECUTABLES" == true ]]; then
  echo -e "${YELLOW}Skipping executable downloads.${NC}"
else
  rm -rf "$EXEC_PATH"
  if [[ "$DEPS_IS_APP" == true ]]; then
    rm "$EXTRACTED_DIR_PATH/Contents/MacOS/iina"*
    rm "$EXTRACTED_DIR_PATH/Contents/MacOS/IINA"*
    mv "$EXTRACTED_DIR_PATH/Contents/MacOS" "$EXEC_PATH" && echo -e "${GREEN}Moved executable to $EXEC_PATH${NC}"
  else
    mv "$EXTRACTED_DIR_PATH/executable" "$EXEC_PATH" && echo -e "${GREEN}Moved executable to $EXEC_PATH${NC}"
  fi
  chmod +x "$EXEC_PATH"/* 2>/dev/null || true
fi

rm -rf "${DEPS_PATH}/${ARCHIVE_NAME}" && echo -e "${GREEN}Removed ${ARCHIVE_NAME}${NC}"
rm -rf "$EXTRACTED_DIR_PATH" && echo -e "${GREEN}Removed extracted directory ${EXTRACTED_DIR_PATH}${NC}"

if [[ "$SKIP_PLUGINS" == true ]]; then
  echo -e "${YELLOW}Skipping official plugin downloads.${NC}"
  echo -e "${GREEN}All downloads completed.${NC}"
  exit 0
fi

mkdir -p "$PLUGIN_PATH"

fetch_latest_plugin_asset() {
  local repo="$1"
  local response_file
  local status_code

  response_file=$(mktemp) || return 1
  status_code=$(curl -s -L -o "$response_file" -w "%{http_code}" "https://api.github.com/repos/${repo}/releases/latest") || {
    echo -e "${RED}Failed to contact GitHub for ${repo}.${NC}" >&2
    rm -f "$response_file"
    return 1
  }

  if [[ "$status_code" -lt 200 || "$status_code" -ge 300 ]]; then
    echo -e "${RED}GitHub API returned HTTP ${status_code} for ${repo}.${NC}" >&2
    python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace").strip()
if not text:
    raise SystemExit(0)
try:
    payload = json.loads(text)
except json.JSONDecodeError:
    print(text[:240], file=sys.stderr)
    raise SystemExit(0)
message = payload.get("message")
if message:
    print(message, file=sys.stderr)
' "$response_file"
    rm -f "$response_file"
    return 1
  fi

  python3 -c '
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
try:
    release = json.loads(text)
except json.JSONDecodeError as exc:
    print(f"Failed to decode GitHub API response as JSON: {exc}", file=sys.stderr)
    preview = text.strip()
    if preview:
        print(preview[:240], file=sys.stderr)
    raise SystemExit(1)
assets = [asset for asset in release.get("assets", []) if asset.get("name", "").endswith(".iinaplgz")]
if not assets:
    message = release.get("message")
    if message:
        print(message, file=sys.stderr)
    else:
        print("Latest release does not contain a .iinaplgz asset.", file=sys.stderr)
    raise SystemExit(1)
asset = assets[0]
print(asset["name"])
print(asset["browser_download_url"])
' "$response_file"
  local status=$?
  rm -f "$response_file"
  return $status
}

download_plugin() {
  local repo="$1"
  local prefix="$2"
  local asset_info
  local asset_name
  local asset_url
  local tmp_path

  echo -e "${YELLOW}Downloading latest plugin release for ${repo}...${NC}"
  asset_info=$(fetch_latest_plugin_asset "$repo") || {
    echo -e "${RED}Failed to fetch the latest plugin asset for ${repo}.${NC}" >&2
    return 1
  }

  asset_name=$(printf "%s\n" "$asset_info" | sed -n "1p")
  asset_url=$(printf "%s\n" "$asset_info" | sed -n "2p")
  tmp_path="${PLUGIN_PATH}/${asset_name}.download"

  curl -s -f -L "$asset_url" -o "$tmp_path" || {
    echo -e "${RED}Failed downloading ${asset_name}.${NC}" >&2
    rm -f "$tmp_path"
    return 1
  }

  find "$PLUGIN_PATH" -maxdepth 1 -type f -name "${prefix}-*.iinaplgz" -delete
  mv "$tmp_path" "${PLUGIN_PATH}/${asset_name}"
  echo -e "${GREEN}Downloaded ${asset_name}${NC}"
}

download_plugin "iina/plugin-online-media" "iina-plugin-ytdl" || exit 1
download_plugin "iina/plugin-userscript" "iina-plugin-userscript" || exit 1
download_plugin "iina/plugin-opensub" "iina-plugin-opensub" || exit 1

echo -e "${GREEN}All downloads completed.${NC}"
