#!/usr/bin/env bash
#
# Install the HPLIP proprietary plugin that HP LaserJet Professional P1108 (and
# other "plugin=1" models) needs. Without it, hpcups dies at job start and CUPS
# logs: "HPCupsFilter.cpp 489: m_Job initialization failed with error = 48"
# followed by "hpcups crashed on signal 11"; the queue stays stuck forever.
#
# Run as root:  sudo bash install-hplip-plugin.sh
# Offline:      HPLIP_PLUGIN_RUN=/path/hplip-3.18.12-plugin.run sudo -E bash install-hplip-plugin.sh
#
set -euo pipefail

MANIFEST_URLS=(
  "https://hplip.sourceforge.io/plugin.conf"
  "http://hplip.sourceforge.net/plugin.conf"
)
PLUGIN_RUN="${HPLIP_PLUGIN_RUN:-}"
WORK_DIR="$(mktemp -d /tmp/hplip-plugin.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAILED:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash $0)"

# ---------------------------------------------------------------- architecture
# $ARCH as used by plugin.spec inside the plugin archive.
case "$(uname -m)" in
  aarch64|armv8*) ARCH=arm64 ;;
  armv7*|armv6*|armv5*|arm) ARCH=arm32 ;;
  x86_64)         ARCH=x86_64 ;;
  i386|i486|i586|i686) ARCH=x86_32 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

HPLIP_CONF=/etc/hp/hplip.conf
[ -r "$HPLIP_CONF" ] || die "$HPLIP_CONF not found - install hplip first (apt install hplip)"

HOMEDIR=$(awk -F= '/^\[dirs\]/{f=1;next} /^\[/{f=0} f && /^[ \t]*home/{gsub(/[ \t]/,"",$2);print $2}' "$HPLIP_CONF")
[ -n "$HOMEDIR" ] && [ -d "$HOMEDIR" ] || die "could not read 'home =' from $HPLIP_CONF"
LJ_SO="$HOMEDIR/prnt/plugins/lj.so"

HPLIP_VERSION=$(dpkg-query -W -f '${Version}' hplip 2>/dev/null | sed 's/+.*//' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
[ -n "$HPLIP_VERSION" ] || die "could not determine the installed HPLIP version"

# ------------------------------------------------------------------ already ok?
if [ -e "$LJ_SO" ]; then
  log "plugin already installed: $(readlink -f "$LJ_SO")"
  exit 0
fi

log "HPLIP $HPLIP_VERSION, arch $ARCH, plugins dir $HOMEDIR/prnt/plugins"

# ------------------------------------------------------------- fetch the .run
RUN="$WORK_DIR/hplip-$HPLIP_VERSION-plugin.run"
if [ -n "$PLUGIN_RUN" ]; then
  [ -r "$PLUGIN_RUN" ] || die "HPLIP_PLUGIN_RUN=$PLUGIN_RUN is not readable"
  cp "$PLUGIN_RUN" "$RUN"
  log "using pre-downloaded plugin archive: $PLUGIN_RUN"
else
  log "reading the plugin manifest"
  MANIFEST=""
  for url in "${MANIFEST_URLS[@]}"; do
    # plugin.conf is CRLF-terminated; the \r would break the section match.
    if MANIFEST=$(curl -fsSL --max-time 30 "$url" 2>/dev/null | tr -d '\r'); then
      log "manifest from $url"
      break
    fi
  done
  [ -n "$MANIFEST" ] || die "could not download the plugin manifest - check the network,
       or fetch hplip-$HPLIP_VERSION-plugin.run yourself and re-run with
       HPLIP_PLUGIN_RUN=/path/to/hplip-$HPLIP_VERSION-plugin.run"

  read -r SRC_URL SRC_SIZE SRC_SHA1 <<EOF
$(printf '%s\n' "$MANIFEST" | awk -v v="$HPLIP_VERSION" '
  /^\[/ { on = ($0 == "[" v "]") }
  on && /^url/      { u = $3 }
  on && /^size/     { s = $3 }
  on && /^checksum/ { c = $3 }
  END { print u, s, c }')
EOF

  [ -n "${SRC_URL:-}" ] || die "HPLIP $HPLIP_VERSION is not listed in plugin.conf.
       The manifest only carries plugins for released versions; upgrade HPLIP or
       download the matching archive manually."
  SRC_URL=${SRC_URL/http:\/\//https:\/\/}
  log "downloading $SRC_URL"
  curl -fsS --retry 2 --progress-bar --max-time 900 -o "$RUN" "$SRC_URL" || die "download failed: $SRC_URL"
  log "checksum: $SRC_SHA1 (expected size: $SRC_SIZE bytes)"
fi

# ------------------------------------------------------------------- verify it
[ -s "$RUN" ] || die "plugin archive is empty"
ACTUAL_SIZE=$(stat -c %s "$RUN")
ACTUAL_SHA1=$(sha1sum "$RUN" | cut -d' ' -f1)
if [ -n "${SRC_SIZE:-}" ] && [ "$ACTUAL_SIZE" != "$SRC_SIZE" ]; then
  die "size mismatch: got $ACTUAL_SIZE, manifest says $SRC_SIZE"
fi
if [ -n "${SRC_SHA1:-}" ] && [ "$ACTUAL_SHA1" != "$SRC_SHA1" ]; then
  die "SHA1 mismatch: got $ACTUAL_SHA1, manifest says $SRC_SHA1 (refusing to install)"
fi
log "archive verified ($ACTUAL_SIZE bytes, sha1 $ACTUAL_SHA1)"

# --------------------------------------------------------------- install it
# hp-plugin is the official installer but expects a terminal, so it is only a
# fallback here. The primary path applies the archive's own plugin.spec mapping
# for print plugins + licence, which is exactly what hp-plugin does on a tty.
extract_dir="$WORK_DIR/extract"
mkdir -p "$extract_dir"
sh "$RUN" --noexec --target "$extract_dir" >/dev/null 2>&1 || die "could not unpack $RUN"

plugin_file() { # basename -> path, the makeself payload is flat
  local f
  for f in "$extract_dir/$1" "$extract_dir"/*/"$1"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

install_manual() {
  local dst="$HOMEDIR/prnt/plugins" src lic name
  mkdir -p "$dst" "$HOMEDIR/data/plugins"

  for name in lj hbpl1; do
    src=$(plugin_file "$name-$ARCH.so") || { warn "$name-$ARCH.so missing from the archive"; return 1; }
    install -m 0755 "$src" "$dst/$name-$ARCH.so"
    ln -sfn "$dst/$name-$ARCH.so" "$dst/$name.so"
    log "installed $dst/$name.so -> $name-$ARCH.so"
  done

  if lic=$(plugin_file license.txt); then
    install -m 0644 "$lic" "$HOMEDIR/data/plugins/license.txt"
  else
    warn "license.txt not found in the archive (not fatal for printing)"
  fi
  return 0
}

if install_manual; then
  log "plugin installed from plugin.spec"
else
  warn "manual install failed, falling back to hp-plugin -i"
  hp-plugin -i -p "$RUN" < /dev/null || true
fi

[ -e "$LJ_SO" ] || die "lj.so is still absent from $HOMEDIR/prnt/plugins - try 'sudo hp-plugin -i'"

# hpcups caches the plugin load failure inside the running daemon.
systemctl restart cups 2>/dev/null || service cups restart 2>/dev/null || warn "restart cups manually"
log "cups restarted"
log "OK: HPLIP plugin for $ARCH is in place"
