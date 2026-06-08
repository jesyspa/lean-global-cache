#!/usr/bin/env bash
# lib/config.sh — resolve the four configurable host settings.
# Sourced by deploy.sh and admin/*.sh (not by bin/lean-cache, which inlines
# equivalent logic to stay a self-contained single file).
#
# Precedence for each setting (highest to lowest):
#   1. Env var:        LEAN_CACHE_OWNER / _GROUP / _ROOT / _BIN
#   2. Config file:    ${LEAN_CACHE_CONF:-/etc/lean-cache.conf}  (sets OWNER/GROUP/ROOT/BIN)
#   3. Built-in default

# Source the config file if present; it may set OWNER, GROUP, ROOT, BIN.
# shellcheck source=/dev/null
[[ -r "${LEAN_CACHE_CONF:-/etc/lean-cache.conf}" ]] \
  && . "${LEAN_CACHE_CONF:-/etc/lean-cache.conf}"

OWNER="${LEAN_CACHE_OWNER:-${OWNER:-$(id -un)}}"
GROUP="${LEAN_CACHE_GROUP:-${GROUP:-$(id -gn)}}"
ROOT="${LEAN_CACHE_ROOT:-${ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/lean-global-cache}}"
BIN="${LEAN_CACHE_BIN:-${BIN:-$HOME/.local/bin/lean-cache}}"
