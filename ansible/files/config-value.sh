#!/usr/bin/env bash
# Prints a variable of jugendhackt-iso.sh's config, for the playbooks:
#   config-value.sh <config file> <variable>
# config is a bash file, so bash reads it. Arrays print one item per line.
# Works with macOS's bash 3.2, which has no namerefs.
set -e
[[ "$2" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "not a variable name: $2" >&2; exit 1; }
source "$1"
eval 'printf "%s\n" "${'"$2"'[@]}"'
