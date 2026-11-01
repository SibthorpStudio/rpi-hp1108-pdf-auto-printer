#!/usr/bin/env bash
#
# Remove the pdfprint service. The CUPS queue and the HPLIP proprietary plugin
# are left alone - they belong to the system printer setup, not to this app.
#
#   sudo bash uninstall.sh            # keep spool/ and printed/
#   sudo bash uninstall.sh --purge    # delete everything under the app dir
#
set -euo pipefail

UNIT=pdfprint
APP_DIR=${PDFPRINT_DIR:-/opt/pdfprint}
CONF=/etc/pdfprint.conf
PURGE=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFAILED:\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -eq 0 ] || [ "$1" = "--purge" ] || die "usage: uninstall.sh [--purge]"
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash uninstall.sh"
if [ "${1:-}" = "--purge" ]; then PURGE=1; fi


if systemctl cat "$UNIT" >/dev/null 2>&1; then
  log "stopping and disabling $UNIT"
  systemctl stop "$UNIT" 2>/dev/null || true
  systemctl disable "$UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$UNIT.service"
  systemctl daemon-reload
else
  log "no $UNIT systemd unit installed"
fi

if [ "$PURGE" -eq 1 ]; then
  [ -d "$APP_DIR" ] || { log "$APP_DIR is already gone"; exit 0; }
  n=$(find "$APP_DIR/spool" "$APP_DIR/printed" -type f 2>/dev/null | wc -l)
  if [ "$n" -gt 0 ]; then
    printf 'Delete %s (%d file(s) in spool/ and printed/)? [y/N] ' "$APP_DIR" "$n"
    read -r answer
    case "$answer" in
      [yY]*) rm -rf "$APP_DIR"; log "removed $APP_DIR" ;;
      *)     log "kept $APP_DIR" ;;
    esac
  else
    rm -rf "$APP_DIR"
    log "removed $APP_DIR (no documents inside)"
  fi
else
  log "kept $APP_DIR (rerun with --purge to delete it)"
fi

if [ -f "$CONF" ]; then
  rm -f "$CONF"
  log "removed $CONF"
fi
log "done"
