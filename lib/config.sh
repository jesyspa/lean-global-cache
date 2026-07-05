#!/usr/bin/env bash
# lib/config.sh — resolve the configurable host settings.
# Sourced by deploy.sh and admin/*.sh (not by bin/lean-cache, which inlines
# equivalent logic to stay a self-contained single file — keep the two in sync).
#
# Precedence for each setting (highest to lowest):
#   1. Env var:     LEAN_CACHE_OWNER / _GROUP / _ROOT / _BIN / _INSTALL_LAKE_SHIM
#   2. Config file: see below
#   3. Built-in default
#
# The single-user default needs no config file. A config file is only for a
# shared, multi-user cache. LEAN_CACHE_CONF, if set, is used exclusively (a
# non-existent path selects no config); otherwise the first of these that
# exists is read:
#   ~/.config/lean-cache/lean-cache.conf   the owner's config (per-user)
#   /etc/lean-cache/lean-cache.conf        system config (multi-user)
#   /etc/lean-cache.conf                   legacy system config
_conf=""
if [[ -n "${LEAN_CACHE_CONF:-}" ]]; then
  [[ -r "$LEAN_CACHE_CONF" ]] && _conf="$LEAN_CACHE_CONF"
else
  for _c in "${XDG_CONFIG_HOME:-$HOME/.config}/lean-cache/lean-cache.conf" \
            /etc/lean-cache/lean-cache.conf /etc/lean-cache.conf; do
    [[ -r "$_c" ]] && { _conf="$_c"; break; }
  done
fi
# shellcheck source=/dev/null
[[ -n "$_conf" ]] && . "$_conf"
unset _c _conf

OWNER="${LEAN_CACHE_OWNER:-${OWNER:-$(id -un)}}"
GROUP="${LEAN_CACHE_GROUP:-${GROUP:-$(id -gn)}}"
ROOT="${LEAN_CACHE_ROOT:-${ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/lean-global-cache}}"
BIN="${LEAN_CACHE_BIN:-${BIN:-$HOME/.local/bin/lean-cache}}"

# Install the transparent `lake` shim ahead of the real lake on PATH? Off by
# default (plain `lake`); a shared, contended host sets this to 1 to route bare
# `lake build` through the build-slot policy.
INSTALL_LAKE_SHIM="${LEAN_CACHE_INSTALL_LAKE_SHIM:-${INSTALL_LAKE_SHIM:-0}}"
