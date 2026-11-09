#!/system/bin/sh
# Earliest pass: enable modem remoteproc recovery, then keep re-applying it
# every 0.2s (1s on BusyBox without fractional sleep) for ~20s in the background, covering the gap before service.sh
# starts and the moment the modem first powers up.
RP="${RP_BASE:-/sys/class/remoteproc}"
CFGF="${CFG_DIR:-/data/adb/modem_recovery_enable}/config.txt"
LOGOFF=1; grep -qE '^logging=on[[:space:]]*$' "$CFGF" 2>/dev/null && LOGOFF=0   # logging is off unless config says logging=on
D="${LOG_DIR:-/data/local/tmp}"
mkdir -p "$D" 2>/dev/null

apply() {
  for r in "$RP"/remoteproc*; do
    [ -e "$r/recovery" ] || continue
    [ -r "$r/name" ] || continue
    n=""; read -r n < "$r/name"
    case "$n" in
      *mss*|*modem*)
        cur=""; read -r cur < "$r/recovery"
        if [ "$cur" != "enabled" ]; then
          echo enabled > "$r/recovery" 2>/dev/null
          [ "$LOGOFF" = 1 ] || echo "post-fs-data uptime $(cut -d' ' -f1 /proc/uptime)s $r: $cur -> $(cat "$r/recovery" 2>/dev/null)" >> "$D/modem_recovery.log" 2>/dev/null
        fi
        ;;
    esac
  done
}

apply
(
  # Some BusyBox builds cannot sleep for a fraction of a second: fall back to 1s steps
  # (5x fewer ticks) so the ~20s early window still lasts ~20s instead of collapsing.
  STEP=0.2; TICKS="${EARLY_TICKS:-100}"
  sleep 0.01 2>/dev/null || { STEP=1; TICKS=$((TICKS / 5)); }
  i=0
  while [ "$i" -lt "$TICKS" ]; do
    apply
    sleep "$STEP"
    i=$((i+1))
  done
) >/dev/null 2>&1 &
exit 0
