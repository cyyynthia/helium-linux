#!/usr/bin/env bash

set -euo pipefail

_root_dir="$(dirname "$(readlink -f "$0")")"
source "$_root_dir/devutils/shared.sh"
_download=true
while getopts 'cd' option; do
  case "$option" in
    c) _download=false ;;
    d) _download=true ;;
    *) echo "Usage: $0 [-c|-d] [x86_64]" >&2; exit 2 ;;
  esac
done
shift "$((OPTIND - 1))"

_arch="${1:-x86_64}"
case "$_arch" in
  x86_64) ;;
  *) echo "Usage: $0 [-c|-d] [x86_64]" >&2; exit 2 ;;
esac

prepare_sources "$_download"
configure_build "$_arch" release

helium_build
