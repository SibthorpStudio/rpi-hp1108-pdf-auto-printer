#!/usr/bin/env bash
#
# One-click installer for Raspberry Pi OS (Debian-based) + HP LaserJet
# Professional P1108: installs the CUPS queue, the HPLIP proprietary plugin the
# P1108 requires, and a persistent web upload-to-print service.
#
#   sudo bash install.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PRINTER_NAME="HP-LaserJet-Professional-P1108"
MODEL_MATCH="p1108"
APP_DIR="/opt/pdfprint"
SERVICE_USER="pdfprint"
PORT="8080"
PAPER=""
SKIP_DEPS=0
SKIP_PLUGIN=0
SKIP_TEST=0
UNIT=pdfprint
CONF=/etc/pdfprint.conf

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAILED:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
usage: install.sh [options]
  --printer NAME    CUPS queue name (default HP-LaserJet-Professional-P1108)
  --model PATTERN   substring used to find the device / PPD (default p1108)
  --dir PATH        install directory (default /opt/pdfprint)
  --user NAME       service user (default pdfprint)
  --port N          listen port (default 8080)
  --paper SIZE      set queue default page size, e.g. A4
  --skip-deps       do not run apt-get
  --skip-plugin     do not touch the HPLIP proprietary plugin
  --skip-test       do not print the self-test page
  -h, --help        this message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --printer) PRINTER_NAME=$2; shift 2 ;;
    --model)   MODEL_MATCH=$2; shift 2 ;;
    --dir)     APP_DIR=$2; shift 2 ;;
    --user)    SERVICE_USER=$2; shift 2 ;;
    --port)    PORT=$2; shift 2 ;;
    --paper)   PAPER=$2; shift 2 ;;
    --skip-deps)   SKIP_DEPS=1; shift ;;
    --skip-plugin) SKIP_PLUGIN=1; shift ;;
    --skip-test)   SKIP_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case "$PORT" in (*[!0-9]*|'') die "--port must be a number" ;; esac
[ -f "$SCRIPT_DIR/app/pdfprint.py" ] || die "run this from the repository root (app/pdfprint.py not found)"

# ------------------------------------------------------------------- preflight
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash install.sh"
grep -qE '^(ID|ID_LIKE)=(raspbian|debian|ubuntu)' /etc/os-release \
  || die "this installer needs a Debian-based OS (Raspberry Pi OS)"
command -v python3 >/dev/null || die "python3 missing"

# ------------------------------------------------------------------- packages
PKGS=(ca-certificates curl python3 python3-cups python3-flask
      cups cups-client printer-driver-hpcups hplip hplip-data)

if [ "$SKIP_DEPS" -eq 0 ]; then
  log "installing packages: ${PKGS[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update failed, continuing with existing package lists"
  if ! apt-get install -y --no-install-recommends "${PKGS[@]}"; then
    missing=()
    for p in "${PKGS[@]}"; do
      dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" \
        || missing+=("$p")
    done
    [ "${#missing[@]}" -eq 0 ] \
      || die "these packages could not be installed: ${missing[*]}
       Check /etc/apt/sources.list (Raspberry Pi OS 'bookworm'/'bullseye' all
       carry them), then re-run."
    warn "apt-get install reported an error but every package is present; continuing"
  fi
fi

# ------------------------------------------------------- HPLIP proprietary plugin
if [ "$SKIP_PLUGIN" -eq 0 ]; then
  log "checking the HPLIP proprietary plugin (P1108 cannot print without it)"
  bash "$SCRIPT_DIR/scripts/install-hplip-plugin.sh"
fi

# --------------------------------------------------------------------- queue
if lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
  log "CUPS queue '$PRINTER_NAME' already exists"
else
  log "looking for the printer on USB"
  URI=$(lpinfo -v | awk -v m="$MODEL_MATCH" 'tolower($0) ~ m && $2 ~ /^hp:/ {print $2; exit}')
  [ -n "$URI" ] || URI=$(lpinfo -v | awk -v m="$MODEL_MATCH" 'tolower($0) ~ m && $2 ~ /^usb:/ {print $2; exit}')
  [ -n "$URI" ] || die "no $MODEL_MATCH device in 'lpinfo -v'.
       Is it powered on and plugged straight into the Pi (no unpowered hub)?
       Re-check the cable, or pass --model for a different HP laser model."
  log "device URI: $URI"

  PPD=$(lpinfo -m | awk -v m="$MODEL_MATCH" 'tolower($0) ~ m && /hpcups/ && $1 ~ /^drv:\/\// {print $1; exit}')
  [ -n "$PPD" ] || PPD="drv:///hpcups.drv/hp-laserjet_professional_${MODEL_MATCH}.ppd"
  log "driver: $PPD"

  lpadmin -p "$PRINTER_NAME" -E -v "$URI" -m "$PPD"
  lpstat -p "$PRINTER_NAME" >/dev/null || die "queue '$PRINTER_NAME' was not created"
fi

if [ -n "$PAPER" ]; then
  log "setting default page size to $PAPER"
  lpadmin -p "$PRINTER_NAME" -o "PageSize=$PAPER"
fi

# --------------------------------------------------------------- service user
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  log "creating system user '$SERVICE_USER'"
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi
# @SYSTEM for CUPS job submission is 'sys root' on Debian; lp is the USB group.
for g in lp sys; do
  getent group "$g" >/dev/null && usermod -aG "$g" "$SERVICE_USER" || true
done

# ------------------------------------------------------------------- app files
log "installing the service into $APP_DIR"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR"
install -m 0644 -o "$SERVICE_USER" -g "$SERVICE_USER" \
  "$SCRIPT_DIR/app/pdfprint.py" "$APP_DIR/pdfprint.py"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR/spool" "$APP_DIR/printed"

if [ ! -f "$CONF" ]; then
  log "writing $CONF"
  install -m 0644 "$SCRIPT_DIR/config/pdfprint.conf.example" "$CONF"
  [ "$PORT" = "8080" ] || sed -i "s|^#PDFPRINT_PORT=.*|PDFPRINT_PORT=$PORT|" "$CONF"
  sed -i "s|^#PDFPRINT_PRINTER=.*|PDFPRINT_PRINTER=$PRINTER_NAME|" "$CONF"
else
  warn "$CONF already exists, leaving it untouched"
fi

# -------------------------------------------------------------------- systemd
log "installing the systemd unit"
sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@DIR@|$APP_DIR|g" \
  "$SCRIPT_DIR/systemd/pdfprint.service" > "/etc/systemd/system/$UNIT.service"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null 2>&1
# restart, not start: an older instance may still hold the port
systemctl restart "$UNIT"
sleep 3
systemctl is-active --quiet "$UNIT" || {
  systemctl status "$UNIT" --no-pager -n 20 || true
  die "$UNIT did not start - see: journalctl -u $UNIT"
}

# ------------------------------------------------------------------ self-test
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ "$SKIP_TEST" -eq 0 ]; then
  log "self-test: uploading a generated PDF through http://127.0.0.1:$PORT/"
  TEST_PDF=$(mktemp /tmp/pdfprint-selftest-XXXX.pdf)
  trap 'rm -f "$TEST_PDF"' EXIT
  TEST_NAME="pdfprint-selftest-$(date +%H%M%S).pdf"
  python3 "$SCRIPT_DIR/scripts/make-test-pdf.py" "$TEST_PDF" "pdfprint self-test"

  if ! RESP=$(curl -fsS --max-time 60 -F "file=@$TEST_PDF;filename=$TEST_NAME" \
      "http://127.0.0.1:$PORT/upload"); then
    journalctl -u "$UNIT" --no-pager -n 20 || true
    die "upload failed - is $UNIT listening on port $PORT?"
  fi
  log "$RESP"

  for _ in $(seq 1 30); do
    sleep 4
    STATUS=$(curl -fsS --max-time 15 "http://127.0.0.1:$PORT/jobs" 2>/dev/null | python3 -c '
import json, sys
try:
    rows = [j for j in json.load(sys.stdin) if j["name"] == sys.argv[1]]
except Exception:
    rows = []
print(rows[-1]["status"] if rows else "unknown")' "$TEST_NAME" 2>/dev/null || echo unknown)
    case "$STATUS" in
      printed)
        log "self-test printed; archived copy:"
        ls -l "$APP_DIR/printed/$TEST_NAME"
        break ;;
      failed)
        die "self-test failed to print. Usual cause: the HPLIP plugin is missing
             or crashed (docs/TROUBLESHOOTING.md). Look at:
               ls -l /usr/share/hplip/prnt/plugins
               journalctl -u $UNIT -n 50
               tail -n 80 /var/log/cups/error_log" ;;
      *) printf '.' ;;
    esac
  done
  [ "$STATUS" = "printed" ] || die "self-test timed out after 120s (last status: $STATUS)"
fi

# -------------------------------------------------------------------- summary
printf '\n'
log "done. PDF upload service is running and will start on boot."
printf '   web UI:   http://%s:%s/\n' "${LAN_IP:-<Pi IP>}" "$PORT"
printf '   printer:  %s\n' "$PRINTER_NAME"
printf '   uploads:  %s/spool  ->  %s/printed (only on success)\n' "$APP_DIR" "$APP_DIR"
printf '   config:   %s   (then: sudo systemctl restart %s)\n' "$CONF" "$UNIT"
printf '   logs:     journalctl -u %s -f\n' "$UNIT"
warn "the web UI has no authentication: anyone who can reach port $PORT can print."
