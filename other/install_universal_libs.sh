#!/bin/bash

# Use color for stderr, in part by redirecting stdout to stderr
# See: https://stackoverflow.com/questions/6841143/how-to-set-font-color-for-stdout-and-stderr
color()(set -o pipefail;"$@" 2>&1>&3|sed $'s,.*,\e[31m&\e[m,'>&2)3>&1

# Verify that necessary tools are present
for cmd in brew otool lipo; do
  printf '%-10s' "$cmd"
  if hash "$cmd" 2>/dev/null; then
    color echo OK
  else
    color echo missing
  fi
done


SCRIPT_PATH=$(realpath "$0")
ROOT_PATH=$(dirname "$SCRIPT_PATH")
color python3 "$ROOT_PATH"/install_universal_libs.py
