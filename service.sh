#!/system/bin/sh
# Modem Recovery Enable v1.31
# - re-applies modem (mss) recovery=enabled every second, forever, so a modem
#   crash restarts the modem instead of rebooting the phone
# - logs every modem fatal error with SIM / network / signal context
# - DUAL SIM (optional, off by default): if the modem crash-loops, powers off ONLY the problem SIM (the one
#   whose provider name is set in config.txt) and turns it back on when it is safe
# - SINGLE SIM: no SIM is ever powered off; the modem just keeps restarting
# - optional airplane-mode breaker (off by default), works with one or two SIMs
D="${LOG_DIR:-/data/local/tmp}"
LOG="$D/modem_recovery.log"
CRASHLOG="$D/modem_crash_reasons.log"
BOOTLOG="$D/last_boot_info.log"
CTXLOG="$D/modem_crash_context.log"
CSV="$D/modem_crash_table.csv"
# Real log paths. When logging is switched off the names above point to /dev/null, so every
# "echo >> $LOG" in this script becomes a no-op and nothing is written.
R_LOG="$LOG"; R_CRASHLOG="$CRASHLOG"; R_BOOTLOG="$BOOTLOG"; R_CTXLOG="$CTXLOG"; R_CSV="$CSV"; LOGGING=on
RP="${RP_BASE:-/sys/class/remoteproc}"
TICK="${TICK:-1}"
SCAN_EVERY="${SCAN_EVERY:-5}"
SIG_EVERY="${SIG_EVERY:-4}"   # sample signal strength every SIG_EVERY scans (default ~20s)
BREAKER_FLAG="${BREAKER_FLAG:-$D/modem_breaker_on}"
BREAKER_COUNT="${BREAKER_COUNT:-5}"
BREAKER_WINDOW="${BREAKER_WINDOW:-120}"
# Visible copy of the logs, readable from any file manager: Internal storage / ModemRecoveryLogs
PUB_BASE="${PUB_BASE:-/sdcard}"
PUB="$PUB_BASE/ModemRecoveryLogs"
# Kernel lines that mean "the modem subsystem died" (qcom q6v5: fatal error / watchdog)
CRASH_RE='fatal error received|fatal error without message|watchdog received|watchdog without message'

mkdir -p "$D" 2>/dev/null
# Some BusyBox builds have no grep -a; use it only when supported.
GA=""; echo x | grep -a x >/dev/null 2>&1 && GA="-a"
# Cap every call into Android services so a hung telephony stack cannot stall the loop.
TO=""; timeout 1 true >/dev/null 2>&1 && TO="timeout 20"
rotate() {
  for f in "$LOG" "$CRASHLOG" "$BOOTLOG" "$CTXLOG" "$CSV"; do
    [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 30000 ] && mv "$f" "$f.old"
  done
}

# The modem remoteproc paths are found once and cached, so the 1-second loop only does two
# cheap shell reads per tick. The cache is rebuilt if a path disappears or none was found yet.
RPS=""
find_rps() {
  RPS=""
  for r in "$RP"/remoteproc*; do
    [ -r "$r/recovery" ] && [ -r "$r/name" ] || continue
    n=""; read -r n < "$r/name"
    case "$n" in *mss*|*modem*) RPS="$RPS $r";; esac
  done
}
enable_recovery() {
  ok=1
  [ -n "$RPS" ] || ok=0
  for r in $RPS; do [ -r "$r/recovery" ] || ok=0; done
  [ "$ok" = 1 ] || find_rps
  for r in $RPS; do
    cur=""; { read -r cur < "$r/recovery"; } 2>/dev/null
    if [ "$cur" != "enabled" ]; then
      n=""; { read -r n < "$r/name"; } 2>/dev/null
      err="$({ echo enabled > "$r/recovery"; } 2>&1)"
      flip_n=$((flip_n+1))
      # log the first 5 flips, then one per 60, so a flapping value cannot flush the log
      if { [ "$flip_n" -le 5 ] || [ $((flip_n % 60)) -eq 0 ]; } && [ ! -f "$D/.logging_off" ]; then
        echo "$(date) uptime $(cut -d' ' -f1 /proc/uptime)s $r ($n): $cur -> $(cat "$r/recovery" 2>/dev/null) (change #$flip_n)${err:+ write error: $err}" >> "$R_LOG"
      fi
    elif [ "$1" = "first" ] && [ ! -f "$D/.logging_off" ]; then
      n=""; { read -r n < "$r/name"; } 2>/dev/null
      echo "$(date) $r ($n): already enabled" >> "$R_LOG"
    fi
  done
}

# Settings live in a root-only file (apps cannot read or change it); a read-only copy is
# shown in Internal storage/ModemRecoveryLogs/config_readonly.txt
CFG_DIR="${CFG_DIR:-/data/adb/modem_recovery_enable}"
CFGF="$CFG_DIR/config.txt"
# The config is read once per scan (cfg_load) and parsed in pure shell, so the many cfg calls
# per scan cost one tiny subshell each instead of four extra processes (sed, tail, tr, sed).
CFG_TXT=""; CR="$(printf '\r')"
cfg_load() {
  new="$(cat "$CFGF" 2>/dev/null)"
  [ -n "$new" ] && CFG_TXT="$new"   # an empty read (file being rewritten) keeps the last good copy
}
cfg() {  # last "key=value" line wins; CR and surrounding spaces are removed
  v=""
  while IFS= read -r l; do
    case "$l" in "$1="*) v="${l#*=}";; esac
  done <<CFGEOF
$CFG_TXT
CFGEOF
  v="${v%"$CR"}"; v="${v#"${v%%[! ]*}"}"; v="${v%"${v##*[! ]}"}"
  printf '%s\n' "$v"
}
put() { printf '%s\n' "$2" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1" 2>/dev/null; }   # atomic: a reader never sees a half-written file
upnow() { cut -d' ' -f1 /proc/uptime | cut -d. -f1; }
num() {  # $1 = value, $2 = fallback. Accepts digits with an optional leading minus; anything else gives the fallback
  case "$1" in
    ''|-|*[!0-9-]*|?*-*|????????????????*) echo "$2";;
    *) printf '%s\n' "$1" | sed 's/^\(-\{0,1\}\)0*\([0-9]\)/\1\2/';;   # 008 -> 8 (a leading 0 means octal in shell arithmetic)
  esac
}

# ---- SIM guard (dual SIM only) -----------------------------------------------
# With TWO SIMs: if the modem crashes GUARD_COUNT times within BREAKER_WINDOW
# seconds, power down ONLY the problem SIM so the modem stops crash-looping and
# the other SIM keeps working; bring it back when it is safe. With ONE SIM the
# guard never runs (powering off the only SIM would cut all service): the modem
# is simply left to restart on its own.
GUARD_COUNT="${GUARD_COUNT:-3}"; PROBATION_COUNT="${PROBATION_COUNT:-2}"
guard_tripped=0; dual_seen=0; single_noted=0; guard_unsupported=0; guard_blocked=0; nokey_noted=0; nomatch_noted=0; TRY_OUT=""
guard_pending=0; pending_at=0; confirm_noted=0; notime_noted=0; gaveup_noted=0; flip_n=0
guard_state=normal; GUARD_SLOT=""; GUARD_SUB=""; guard_fails=0; GUARD_OFF_AT=0; retries=0; good=0; probation_until=0; SIG_NEW=0
MIN_SECS="${MIN_SECS:-60}"; PROBATION_S="${PROBATION_S:-300}"
GOOD_OPRAW=""
guard_set_off() { sync_dirty=1; GUARD_SLOT="$slot"; GUARD_OFF_AT="$(upnow)"; guard_state=off; good=0; put "$D/.sim_off_slot" "$slot"; put "$D/.sim_off_sub" "$GUARD_SUB"; }
get_rsrp() {  # $1 = slot 0/1; prints LTE rsrp (or NR ssRsrp) from the last signal sample
  eval "sg=\$SNAP_SIG$1"
  r="$(printf ' %s' "$sg" | sed -n 's/.* rsrp=\(-[0-9][0-9]*\).*/\1/p')"
  [ -z "$r" ] && r="$(printf ' %s' "$sg" | sed -n 's/.* ssRsrp=\(-[0-9][0-9]*\).*/\1/p')"
  echo "$r"
}
guard_power_on() {  # Android 17: SIMs are switched by subscription id, not slot
  [ -n "$GUARD_SUB" ] || return 1
  try_cmd cmd phone enable-physical-subscription "$GUARD_SUB" && return 0
  return 1
}
sub_of_slot() {  # prints the subscription id of the SIM in 0-based slot $1 (empty if none)
  want="$1"
  $TO content query --uri content://telephony/siminfo --projection _id:sim_id 2>/dev/null | tr -d '\r' | while IFS= read -r l; do
    sid="$(printf '%s' "$l" | sed -n 's/.*[ ,]_id=\([0-9][0-9]*\).*/\1/p')"
    sl="$(printf '%s' "$l" | sed -n 's/.*sim_id=\(-\{0,1\}[0-9][0-9]*\).*/\1/p')"
    [ -n "$sid" ] && [ "$sl" = "$want" ] && { echo "$sid"; break; }
  done | head -n 1
}
sub_of_slot_isub() {  # fallback: read it from dumpsys isub
  $TO dumpsys isub 2>/dev/null | tr '{}' '\n\n' | tr -d '\r' | sed -n "s/^ *id=\([0-9][0-9]*\),.*simSlotIndex=$1,.*/\1/p" | head -n 1
}
guard_fail_note() {  # after 3 failed power-downs stop trying for this boot
  guard_fails=$((guard_fails+1))
  if [ "$guard_fails" -ge 3 ]; then
    guard_unsupported=1
    echo "$(date) GUARD: SIM power-down failed 3 times. SIM guard disabled for this boot; the modem just keeps restarting on its own." >> "$LOG"
  fi
}
slot_of() {  # prints 0-based slot whose provider name contains keyword $1
  want="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; i=0; old="$IFS"; IFS=,
  for o in $GOOD_OPRAW; do
    have="$(printf '%s' "$o" | tr 'A-Z' 'a-z')"
    case "$have" in *"$want"*) IFS="$old"; echo "$i"; return;; esac
    i=$((i+1))
  done
  IFS="$old"
}
try_cmd() {  # run a command, log output, succeed only if no error text
  out="$($TO "$@" 2>&1 </dev/null)"; rc=$?; TRY_OUT="$out"
  echo "$(date) GUARD: $* -> rc=$rc ${out:-(no output)}" >> "$LOG"
  [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qiE "error|usage|unknown|exception|not found|not allowed|cannot|can.t|failed"
}
cmd_probe_done=0
probe_phone_cmd() {  # informational only: never blocks the guard, because hidden commands may still work
  [ "$cmd_probe_done" = 1 ] && return
  cmd_probe_done=1
  ph="$($TO cmd phone help 2>&1 </dev/null)"
  if printf '%s' "$ph" | grep -q "physical-subscription"; then
    echo "$(date) GUARD: this ROM's 'cmd phone' lists the SIM power commands" >> "$LOG"
  else
    echo "$(date) GUARD: this ROM's 'cmd phone help' does not list disable-physical-subscription (it may still work; the guard will try it and disable itself if it fails)" >> "$LOG"
  fi
}
guard_act() {
  [ "$guard_unsupported" = 1 ] && return 1
  key="$(cfg problem_sim)"
  if [ -z "$key" ] || [ "$key" = "YourProvider" ] || [ "$key" = "YourOperator" ]; then
    [ "$nokey_noted" = 1 ] || echo "$(date) GUARD: problem_sim is not set in config.txt (replace YourProvider with your provider name); SIM guard idle" >> "$LOG"
    nokey_noted=1
    return 1
  fi
  if [ "$(cfg confirm_problem_sim)" = no ]; then
    if [ "$confirm_noted" = 0 ]; then
      echo "$(date) GUARD: config.txt came from an older version; SIM guard idle until you check problem_sim=$key and set confirm_problem_sim=yes" >> "$LOG"
      confirm_noted=1
    fi
    return 1
  fi
  slot="$(slot_of "$key")"
  if [ -z "$slot" ]; then
    [ "$nomatch_noted" = 1 ] || echo "$(date) GUARD: no provider matching '$key' in '$GOOD_OPRAW'; no action" >> "$LOG"
    nomatch_noted=1
    return 1
  fi
  nomatch_noted=0
  GUARD_SUB="$(sub_of_slot "$slot")"
  [ -z "$GUARD_SUB" ] && GUARD_SUB="$(sub_of_slot_isub "$slot")"
  if [ -z "$GUARD_SUB" ]; then
    echo "$(date) GUARD: no subscription id found for SIM slot $slot; no action" >> "$LOG"
    echo "$(date) GUARD: siminfo said: $($TO content query --uri content://telephony/siminfo --projection _id:sim_id 2>&1 | head -n 4 | tr '\n\r' '||' | cut -c1-300)" >> "$LOG"
    guard_fail_note; return 1
  fi
  probe_phone_cmd
  echo "$(date) GUARD: modem crash loop, powering down SIM slot $slot ($key, sub $GUARD_SUB); other SIM left on" >> "$LOG"
  try_cmd cmd phone disable-physical-subscription "$GUARD_SUB" && {
    guard_set_off
    return 0
  }
  if printf '%s' "$TRY_OUT" | grep -qiE "permission denied|securityexception|not allowed"; then
    guard_unsupported=1; guard_blocked=1
    echo "$(date) GUARD: this ROM refuses the SIM power command (permission denied, even for root). SIM guard stopped for this boot; if the modem crash-loops, turn the problem SIM off by hand in Settings > SIM manager." >> "$LOG"
    return 1
  fi
  if printf '%s' "$TRY_OUT" | grep -qiE "unknown command|not found|usage"; then
    guard_unsupported=1
    echo "$(date) GUARD: this ROM has no 'cmd phone disable-physical-subscription'. SIM guard disabled; the modem just keeps restarting on its own." >> "$LOG"
    return 1
  fi
  echo "$(date) GUARD: could not power down slot $slot. Turn that SIM off in Settings > SIM manager." >> "$LOG"
  guard_fail_note
  return 1
}

# Auto turn-on: after the guard powered a SIM down, bring it back when it is
# safe. A powered-down SIM has no signal to read, so the OTHER SIM's signal is
# used as a stand-in for local coverage. Settings (config.txt, all optional):
# auto_on, retry_minutes(10), stable_minutes(5), strong_rsrp(-100), max_retries(3)
guard_tick() {
  [ "$guard_state" = normal ] && return
  now="$(upnow)"
  if [ "$guard_state" = probation ]; then
    if [ "$now" -ge "$probation_until" ]; then
      guard_state=normal; retries=0; guard_tripped=0; hist=""; gaveup_noted=0; sync_dirty=1
      echo "$(date) GUARD: SIM slot $GUARD_SLOT stable after turn-on, guard re-armed" >> "$LOG"
    fi
    return
  fi
  [ "$guard_state" = off ] || return
  [ "$(cfg auto_on)" = off ] && return
  RETRY_MIN="$(num "$(cfg retry_minutes)" 10)"; STABLE_MIN="$(num "$(cfg stable_minutes)" 5)"
  STRONG="$(num "$(cfg strong_rsrp)" -100)"; MAXR="$(num "$(cfg max_retries)" 3)"
  if [ "$SIG_NEW" = 1 ]; then
    SIG_NEW=0
    other=$((1 - GUARD_SLOT)); r="$(get_rsrp "$other")"
    # A powered-off SIM has no signal. If the system then lists only the live SIM's line
    # (it lands in the first slot), the other slot reads empty: use the powered-off slot's reading.
    [ -z "$r" ] && r="$(get_rsrp "$GUARD_SLOT")"
    if [ -n "$r" ] && [ "$r" -ge "$STRONG" ]; then good=$((good+1)); else good=0; fi
  fi
  if [ "$retries" -ge "$MAXR" ]; then
    if [ "$gaveup_noted" = 0 ]; then
      gaveup_noted=1
      echo "$(date) GUARD: auto turn-on gave up after $MAXR tries; SIM slot $GUARD_SLOT stays off until the next reboot or until you turn it on in Settings > SIM manager." >> "$LOG"
    fi
    return
  fi
  wait=$((RETRY_MIN * MIN_SECS * (retries + 1)))
  [ $((now - GUARD_OFF_AT)) -lt "$wait" ] && return
  need=$((STABLE_MIN * MIN_SECS / (SCAN_EVERY * TICK * SIG_EVERY))); [ "$need" -lt 1 ] && need=1
  [ "$good" -ge "$need" ] || return
  echo "$(date) GUARD: other SIM strong (>= ${STRONG} dBm) for $good samples, turning SIM slot $GUARD_SLOT back on (try $((retries+1)) of $MAXR)" >> "$LOG"
  if guard_power_on; then
    guard_state=probation; probation_until=$((now + PROBATION_S)); rm -f "$D/.sim_off_slot" "$D/.sim_off_sub"; sync_dirty=1
  else
    retries=$((retries+1)); GUARD_OFF_AT="$now"; good=0
    echo "$(date) GUARD: turn-on failed. Turn the SIM on in Settings > SIM manager." >> "$LOG"
  fi
}

# After a reboot the guard forgets it powered a SIM down. If it left a marker file, turn
# that SIM back on once telephony is up and watch it on probation (a new crash powers it
# off again), so a reboot can never leave a SIM switched off for good.
resume_pending=0; resume_slot=""; resume_sub=""; RESUME_AFTER="${RESUME_AFTER:-90}"
load_resume() {  # also runs when the worker is restarted, so a SIM left off by a dead worker is turned back on
  resume_pending=0
  [ -f "$D/.sim_off_slot" ] || return 0
  resume_slot="$(cat "$D/.sim_off_slot" 2>/dev/null)"; resume_sub="$(cat "$D/.sim_off_sub" 2>/dev/null)"
  case "$resume_slot" in 0|1) resume_pending=1 ;; *) rm -f "$D/.sim_off_slot" "$D/.sim_off_sub" ;; esac
}
guard_resume() {
  [ "$resume_pending" = 1 ] || return
  [ "$(getprop sys.boot_completed)" = "1" ] || return
  [ "$(upnow)" -ge "$RESUME_AFTER" ] || return
  resume_pending=0
  if [ "$(cfg auto_on)" = off ]; then
    echo "$(date) GUARD: SIM slot $resume_slot was powered down before the last reboot and auto_on=off, so it stays off. Turn it on in Settings > SIM manager." >> "$LOG"
    return
  fi
  GUARD_SLOT="$resume_slot"; GUARD_SUB="$resume_sub"
  echo "$(date) GUARD: SIM slot $GUARD_SLOT was powered down before the last reboot, turning it on (probation)" >> "$LOG"
  if guard_power_on; then
    guard_state=probation; guard_tripped=1; probation_until=$(( $(upnow) + PROBATION_S )); rm -f "$D/.sim_off_slot" "$D/.sim_off_sub"; sync_dirty=1
  else
    echo "$(date) GUARD: turn-on failed. Turn the SIM on in Settings > SIM manager." >> "$LOG"
  fi
}

guard_deferred() {  # a crash loop was seen before the SIM state was known: decide as soon as it is
  [ "$guard_pending" = 1 ] || return
  if [ "$dual_seen" != 1 ]; then
    if [ -n "$SNAP_SIM" ]; then
      guard_pending=0
      if [ "$single_noted" = 0 ]; then
        single_noted=1
        echo "$(date) GUARD: crash loop seen but only one SIM present: SIM guard skipped, modem keeps restarting on its own" >> "$LOG"
      fi
    elif [ $(( $(upnow) - pending_at )) -gt "$BREAKER_WINDOW" ]; then
      guard_pending=0
    fi
    return
  fi
  guard_pending=0
  [ "$guard_state" = normal ] && [ "$guard_tripped" = 0 ] && [ "$guard_unsupported" = 0 ] || return
  [ "$(cfg sim_guard)" != on ] && return
  [ $(( $(upnow) - pending_at )) -le "$BREAKER_WINDOW" ] || return
  guard_tripped=1
  if guard_act; then hist=""; else guard_tripped=0; fi
}

hist=""; tripped=0; tripped_at=0; ap_n=0
# If the module turned airplane mode on and the user has since turned it off, forget it,
# so uninstalling later never switches airplane mode off for them.
airplane_flag_check() {
  [ -f "$D/.airplane_by_module" ] || return
  ap_n=$((ap_n+1)); [ "$ap_n" -ge 12 ] || return; ap_n=0
  [ $(( $(upnow) - tripped_at )) -gt 30 ] || return
  [ "$($TO settings get global airplane_mode_on 2>/dev/null)" = 0 ] && rm -f "$D/.airplane_by_module"
}
breaker_check() {  # uses $n (crashes in window) and $now from note_crash
  # re-arm the airplane breaker after BREAKER_REARM seconds so a later crash loop can trip it again
  [ "$tripped" = 1 ] && [ $((now - tripped_at)) -gt "${BREAKER_REARM:-600}" ] && tripped=0
  if [ "$n" -ge "$BREAKER_COUNT" ] && [ "$tripped" = 0 ] && { [ -f "$BREAKER_FLAG" ] || [ "$(cfg breaker)" = on ]; }; then
    tripped=1; tripped_at="$now"
    # Only mark it as ours when it was off: if airplane mode was already on (the user's choice),
    # uninstalling must never switch it off.
    if [ "$($TO settings get global airplane_mode_on 2>/dev/null)" = 1 ]; then
      echo "$(date) BREAKER: $n modem crashes within ${BREAKER_WINDOW}s, airplane mode already on (left as is)" >> "$LOG"
      return
    fi
    : > "$D/.airplane_by_module"
    echo "$(date) BREAKER: $n modem crashes within ${BREAKER_WINDOW}s, turning airplane mode on" >> "$LOG"
    $TO cmd connectivity airplane-mode enable >> "$LOG" 2>&1 || {
      $TO settings put global airplane_mode_on 1
      $TO am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
    }
  fi
}
note_crash() {  # $1 = crash timestamp, $2 = newest dmesg timestamp (both dmesg clock, whole seconds)
  now="$(upnow)"
  ct="$(num "$1" "")"; kn="$(num "$2" "")"
  [ -z "$ct" ] && ct="$now"; [ -z "$kn" ] && kn="$ct"
  # dmesg's clock stops during suspend, /proc/uptime does not, so "recent" is
  # judged against dmesg's own newest line. Crashes already in dmesg when we
  # first look (or re-read after a ring-buffer wrap) are logged but must not
  # trip the guard/breaker.
  [ $((kn - ct)) -gt "$BREAKER_WINDOW" ] && return
  keep=""; n=0
  for t in $hist $ct; do
    if [ $((ct - t)) -le "$BREAKER_WINDOW" ]; then keep="$keep $t"; n=$((n+1)); fi
  done
  hist="$keep"
  if [ "$guard_state" = probation ]; then
    # One crash right after turn-on is normal (the modem restarts when a SIM is switched on):
    # only power the SIM down again when PROBATION_COUNT crashes land inside the window.
    if [ "$n" -lt "$PROBATION_COUNT" ]; then
      echo "$(date) GUARD: modem crashed during probation ($n of $PROBATION_COUNT needed in ${BREAKER_WINDOW}s), SIM slot $GUARD_SLOT stays on" >> "$LOG"
      breaker_check
      return
    fi
    retries=$((retries+1)); guard_tripped=1
    echo "$(date) GUARD: modem crashed during probation, powering SIM slot $GUARD_SLOT down again (retry $retries)" >> "$LOG"
    slot="$GUARD_SLOT"; GUARD_OFF_AT="$now"
    [ "$guard_unsupported" = 1 ] && { breaker_check; return; }
    if try_cmd cmd phone disable-physical-subscription "$GUARD_SUB"; then
      guard_state=off; good=0; hist=""; sync_dirty=1; put "$D/.sim_off_slot" "$slot"; put "$D/.sim_off_sub" "$GUARD_SUB"
    else
      echo "$(date) GUARD: could not power SIM slot $slot down; it stays on probation. Turn that SIM off in Settings > SIM manager." >> "$LOG"
      guard_fail_note
    fi
    breaker_check
    return
  fi
  if [ "$n" -ge "$GUARD_COUNT" ] && [ "$guard_tripped" = 0 ] && [ "$guard_unsupported" = 0 ] && [ "$(cfg sim_guard)" = on ]; then
    if [ "$dual_seen" = 1 ]; then
      guard_tripped=1
      if guard_act; then hist=""; n=0   # SIM is off now: the breaker only fires if crashes continue anyway
      else guard_tripped=0; fi          # could not act: try again on the next crash
    elif [ -z "$SNAP_SIM" ]; then   # SIM state not known yet (telephony still starting): decide as soon as it is
      guard_pending=1; pending_at="$now"
    elif [ "$single_noted" = 0 ]; then
      single_noted=1
      echo "$(date) GUARD: $n crashes but only one SIM seen: SIM guard skipped, modem keeps restarting on its own" >> "$LOG"
    fi
  fi
  breaker_check
}

# ---- Per-crash context: which SIM / network / signal was active -------------
# Everything here (props + signal strength via dumpsys) is sampled every
# SIG_EVERY scans (~20s). On a crash, the LAST sample taken BEFORE the crash is logged.
# Slot order follows the comma-separated props: first value = SIM slot 1.
clean() { tr ',\n' '/ ' | sed 's/ *$//' | cut -c1-"${1:-80}"; }
SNAP_T=""; SNAP_NET=""; SNAP_OP=""; SNAP_SIM=""; SNAP_DATA=""; SNAP_SIG0=""; SNAP_SIG1=""; SNAP_SIGT=""
sig_fields() {
  grep $GA -oE "(rsrp|rsrq|rssnr|ssRsrp|ssRsrq)[ ]*=[ ]*-?[0-9]+" | grep $GA -v "2147483647" | tr -d ' ' | tr '\n' ' ' | cut -c1-160
}
sample_signal() {
  sraw="$($TO dumpsys telephony.registry 2>/dev/null | grep $GA "mSignalStrength=")"
  SNAP_SIGRAW="$sraw"
  SNAP_SIG0="$(printf '%s\n' "$sraw" | sed -n 1p | sig_fields)"
  SNAP_SIG1="$(printf '%s\n' "$sraw" | sed -n 2p | sig_fields)"
  SNAP_DATA="$($TO settings get global multi_sim_data_call 2>/dev/null | clean 12)"
  SNAP_SIGT="$(date +%T)"; SIG_NEW=1
}
snap_init=0
snapshot() {  # runs every SIG_EVERY scans (default ~20s) to keep background work low
  snapn=$((snapn+1))
  [ "$snapn" -ge "$SIG_EVERY" ] || [ "$snap_init" = 0 ] || return
  snap_init=1; snapn=0
  SNAP_T="$(date +%T)"
  SNAP_NET="$(getprop gsm.network.type | clean 40)"
  rawop="$(getprop gsm.operator.alpha)"; rawsim="$(getprop gsm.sim.state)"
  SNAP_OP="$(printf '%s' "$rawop" | clean 60)"
  SNAP_SIM="$(printf '%s' "$rawsim" | clean 40)"
  learn_ops "$rawop"; GOOD_OPRAW="$OP0,$OP1"
  count_sims "$rawsim"
  # dumpsys is the heaviest call here: only take a signal sample when it is used (the crash
  # context log, or the guard waiting for a strong signal to turn a SIM back on)
  if [ "$LOGGING" = on ] || [ "$guard_state" = off ]; then sample_signal; fi
}
snapn=0; OP0=""; OP1=""
learn_ops() {  # keep the last non-empty provider name seen for each slot
  old="$IFS"; IFS=,; set -- $1; IFS="$old"
  [ -n "$(printf '%s' "$1" | tr -d ' ')" ] && OP0="$1"
  [ -n "$(printf '%s' "$2" | tr -d ' ')" ] && OP1="$2"
}
count_sims() {  # two SIMs seen at once => dual SIM; sticky, because a crashing SIM can flicker to ABSENT
  old="$IFS"; IFS=,; set -- $1; IFS="$old"; c=0
  for st in "$@"; do
    case "$st" in ''|*ABSENT*|*UNKNOWN*) ;; *) c=$((c+1));; esac
  done
  [ "$c" -ge 2 ] && dual_seen=1
}
log_context() {  # $1 = crash line
  msg="$(printf '%s' "$1" | sed -e 's/.*fatal error received: *//' -e 's/.*watchdog received: *//' | clean 120)"
  case "$1" in *watchdog*) msg="WATCHDOG $msg";; esac
  [ -f "$CSV" ] || echo "time,uptime_s,network_type(slot1/slot2),provider(slot1/slot2),sim_state,data_subid,signal_phone0,signal_phone1,signal_sampled_at,crash" > "$CSV"
  echo "$(date +%T),$(cut -d' ' -f1 /proc/uptime),$SNAP_NET,$SNAP_OP,$SNAP_SIM,$SNAP_DATA,$(printf '%s' "$SNAP_SIG0" | clean 90),$(printf '%s' "$SNAP_SIG1" | clean 90),$SNAP_SIGT,$msg" >> "$CSV"
  {
    echo "=== $(date)  crash: $msg"
    echo "  last sample before crash at $SNAP_T"
    echo "  network type (slot1,slot2): $SNAP_NET"
    echo "  provider     (slot1,slot2): $SNAP_OP"
    echo "  sim state                 : $SNAP_SIM"
    echo "  data subscription id      : $SNAP_DATA"
    echo "  signal phone0: ${SNAP_SIG0:-n/a}   phone1: ${SNAP_SIG1:-n/a}   (sampled $SNAP_SIGT)"
    printf '%s\n' "$SNAP_SIGRAW" | cut -c1-300 | sed 's/^/  raw: /'
  } >> "$CTXLOG"
}

guard_ui_text() {  # one short line for the status page
  gk="$(cfg problem_sim)"
  if [ "$(cfg sim_guard)" != on ]; then echo "Off (sim_guard=off)"
  elif [ "$guard_blocked" = 1 ]; then echo "Blocked by ROM (SIM power command refused)"
  elif [ "$guard_unsupported" = 1 ]; then echo "Unsupported on this ROM"
  elif [ -z "$gk" ] || [ "$gk" = "YourProvider" ] || [ "$gk" = "YourOperator" ]; then echo "Idle: set problem_sim in the root-only config.txt"
  elif [ "$(cfg confirm_problem_sim)" = no ]; then echo "Idle: confirm problem_sim in the root-only config.txt"
  elif [ "$guard_state" = off ]; then echo "SIM slot ${GUARD_SLOT:-?} is powered down"
  elif [ "$guard_state" = probation ]; then echo "SIM slot ${GUARD_SLOT:-?} is back on, being watched"
  elif [ "$dual_seen" != 1 ]; then echo "Idle: single SIM"
  else echo "Armed (problem SIM: $gk)"; fi
}

# Copy logs to internal storage once it is available (not at early boot).
SYNC_EVERY="${SYNC_EVERY:-60}"
SYNC_SCANS=$((SYNC_EVERY / (SCAN_EVERY * TICK))); [ "$SYNC_SCANS" -lt 1 ] && SYNC_SCANS=1
sync_n=0; sync_dirty=1
all_crash() { cat "$CRASHLOG.old" "$CRASHLOG" 2>/dev/null; }   # rotated + current crash log
all_csv() { { [ -f "$CSV.old" ] && tail -n +2 "$CSV.old"; [ -f "$CSV" ] && tail -n +2 "$CSV"; } 2>/dev/null; }
# Logging switch (config: logging=on|off, default off). Off = no log, crash, CSV, summary or dmesg file is
# written, nothing is copied to storage. The marker file lets the separate recovery loop know.
set_logging() {
  if [ "$(cfg logging)" != on ]; then   # logging is OFF unless config says logging=on
    [ "$LOGGING" = off ] && return
    LOGGING=off; : > "$D/.logging_off"
    LOG=/dev/null; CRASHLOG=/dev/null; BOOTLOG=/dev/null; CTXLOG=/dev/null; CSV=/dev/null
  else
    [ "$LOGGING" = on ] && return
    LOGGING=on; rm -f "$D/.logging_off" "$D/.logs_purged"
    LOG="$R_LOG"; CRASHLOG="$R_CRASHLOG"; BOOTLOG="$R_BOOTLOG"; CTXLOG="$R_CTXLOG"; CSV="$R_CSV"
    sync_dirty=1
    run_boot_diag
  fi
}
# v1.31: logging off = no logs anywhere. Delete the folder in Internal storage and the module's own
# log copies and the crash counter (it only counts while logging is on). Runs again only if the folder shows up again (storage mounted late), so it is cheap.
purge_logs() {
  [ "$LOGGING" = off ] || return
  [ -d "$PUB" ] || [ ! -f "$D/.logs_purged" ] || return
  rm -f "$R_LOG" "$R_LOG.old" "$R_CRASHLOG" "$R_CRASHLOG.old" "$R_BOOTLOG" "$R_BOOTLOG.old" \
        "$R_CTXLOG" "$R_CTXLOG.old" "$R_CSV" "$R_CSV.old" "$D/.new_crash" "$D/.tagged" "$D/.crash_total" 2>/dev/null
  [ -d "$PUB" ] && rm -rf "$PUB" 2>/dev/null
  : > "$D/.logs_purged"
}
# v1.31: SIM guard off also turns auto_on off; SIM guard on turns it back on. Acts on the change of
# sim_guard (from the Settings card or a hand edit), so a later manual auto_on choice is kept.
cfg_set() {  # atomic: write key=value into the root-only config
  { grep -v "^$1=" "$CFGF" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$CFGF.tmp" 2>/dev/null \
    && chmod 600 "$CFGF.tmp" && mv -f "$CFGF.tmp" "$CFGF" && cfg_load
}
SG_PREV="$(cat "$D/.sg_last" 2>/dev/null)"
sync_auto_on() {
  [ -f "$CFGF" ] || return
  if [ "$(cfg sim_guard)" = on ]; then cur=on; else cur=off; fi
  [ "$cur" = "$SG_PREV" ] && return
  if [ "$cur" = on ]; then
    # first run after upgrade (no previous value): leave auto_on as the user has it
    [ -n "$SG_PREV" ] && [ "$(cfg auto_on)" != on ] && { cfg_set auto_on on; echo "$(date) CONFIG: sim_guard turned on, auto_on set to on" >> "$LOG"; }
  else
    [ "$(cfg auto_on)" != off ] && { cfg_set auto_on off; echo "$(date) CONFIG: sim_guard is off, auto_on set to off" >> "$LOG"; }
  fi
  SG_PREV="$cur"; put "$D/.sg_last" "$cur"
}
scan_needed() {  # with logging off, dmesg is still read (in memory only) while the SIM guard or breaker needs crash events
  [ "$LOGGING" = on ] && return 0
  [ "$(cfg sim_guard)" = on ] && return 0
  [ -f "$BREAKER_FLAG" ] || [ "$(cfg breaker)" = on ] && return 0
  return 1
}
GUI_LAST=""
write_guard_ui() {  # one-line SIM guard state for the status page (internal state file, not a log)
  t="$(guard_ui_text)"
  [ "$t" = "$GUI_LAST" ] && return
  GUI_LAST="$t"; put "$D/.guard_ui" "$t"
}
ensure_config() {  # create the root-only settings file, and mark an old-format one for confirmation
  mkdir -p "$CFG_DIR" 2>/dev/null; chmod 700 "$CFG_DIR" 2>/dev/null
  if [ ! -f "$CFGF" ]; then
    cat > "$CFGF" <<'CFG'
# Modem Recovery Enable settings. Root-only file: apps cannot read or change it.
# Edit it as root (root file manager or: su -c nano <this file>); applies on the next crash.
# config format: v1.26
# logging=off : (default) write no logs at all; the SIM guard and airplane breaker still work.
# logging=on  : save crash logs and copy them to Internal storage/ModemRecoveryLogs.
#               Switching it back off DELETES that folder, the saved logs and the crash counter.
logging=off
# sim_guard=off : (default) the SIM guard never runs; the modem just restarts on its own.
# sim_guard=on  : DUAL SIM only. After 3 modem crashes in 2 minutes, power down ONLY
#                 the problem SIM so the other SIM keeps working. Also set problem_sim below.
#                 Some ROMs refuse the SIM power command; the guard then stops and says so.
#                 With a single SIM the guard never runs; the modem just restarts.
#                 Turning sim_guard off also sets auto_on=off; turning it on sets auto_on=on.
sim_guard=off
# problem_sim = part of the provider name shown for the SIM that causes crashes
problem_sim=YourProvider
# breaker=on : turn airplane mode on after 5 modem crashes within 2 minutes
#              (off by default; works with one or two SIMs; turn airplane mode off by hand)
breaker=off
# auto_on=on : after the guard turns a SIM off, turn it back on when the OTHER SIM's
#              signal has been strong for stable_minutes (a powered-off SIM cannot be measured).
auto_on=on
# purge_on_uninstall=yes : (default) delete this folder, the settings and the logs in Internal storage
#                          when the module is removed. Use "no" to keep them for a reinstall.
purge_on_uninstall=yes
retry_minutes=10
stable_minutes=5
strong_rsrp=-100
max_retries=3
CFG
  fi
  chmod 600 "$CFGF" 2>/dev/null
  if ! grep -qE "config format: v1\.(2[5-9]|[3-9][0-9])" "$CFGF" 2>/dev/null; then
    echo "$(date) NOTE: config.txt ($CFGF) was made by an older version and is kept as is. The SIM guard stays idle until you check problem_sim=$(cfg problem_sim) and set confirm_problem_sim=yes." >> "$LOG"
    [ -n "$(tail -c 1 "$CFGF" 2>/dev/null)" ] && echo >> "$CFGF"   # file may not end with a newline
    printf '%s\n' '# config format: v1.26 (older file kept as is)' \
      '# The SIM guard stays idle until you check problem_sim above, then change the next line to yes:' \
      'confirm_problem_sim=no' >> "$CFGF" 2>/dev/null
  fi
  cfg_load
}
sync_logs() {
  sync_n=$((sync_n+1))
  [ "$sync_dirty" = 1 ] || [ "$sync_n" -ge "$SYNC_SCANS" ] || return
  rotate
  [ "$(getprop sys.boot_completed)" = "1" ] || return
  [ -d "$PUB_BASE/Android" ] || return
  # one-time move of a config.txt left in shared storage by v1.26 or older (apps could edit it)
  if [ -f "$PUB/config.txt" ] && [ ! -f "$CFG_DIR/.migrated" ]; then
    mkdir -p "$CFG_DIR" 2>/dev/null; chmod 700 "$CFG_DIR" 2>/dev/null
    cp -f "$PUB/config.txt" "$CFGF" 2>/dev/null && : > "$CFG_DIR/.migrated" && rm -f "$PUB/config.txt"
    echo "$(date) NOTE: settings moved to $CFGF (root only). Edit that file; $PUB/config_readonly.txt is a read-only copy." >> "$LOG"
    ensure_config
  fi
  # Storage is up and there was nothing to migrate: close the migration for good, so an app can
  # never drop a config.txt in shared storage and have it copied over the root-only settings.
  if [ ! -f "$CFG_DIR/.migrated" ] && [ ! -f "$PUB/config.txt" ]; then mkdir -p "$CFG_DIR" 2>/dev/null; : > "$CFG_DIR/.migrated"; fi
  [ -f "$CFG_DIR/.migrated" ] && [ -f "$PUB/config.txt" ] && rm -f "$PUB/config.txt"   # ignored now, avoid confusion
  if [ "$LOGGING" = off ]; then sync_n=0; sync_dirty=0; return; fi   # logging off: write nothing to storage
  mkdir -p "$PUB" 2>/dev/null || return
  sync_n=0; sync_dirty=0
  for f in "$LOG" "$CRASHLOG" "$BOOTLOG" "$CTXLOG" "$CSV"; do
    [ -f "$f" ] && cp -f "$f" "$PUB/" 2>/dev/null
    [ -f "$f.old" ] && cp -f "$f.old" "$PUB/" 2>/dev/null
  done
  if [ -f "$CFGF" ]; then
    { echo "# READ-ONLY COPY - changes here are ignored. Real settings: $CFGF (root only)"; cat "$CFGF"; } > "$PUB/config_readonly.txt" 2>/dev/null
    chmod 444 "$PUB/config_readonly.txt" 2>/dev/null
  fi
  dmesg 2>/dev/null | grep $GA -iE "$CRASH_RE|fatal error|watchdog|remoteproc|subsystem failure|recovery state|mpss" | tail -n 200 > "$PUB/modem_dmesg_tail.txt" 2>/dev/null
  {
    echo "Modem Recovery Enable - summary (updated $(date))"
    echo "uptime: $(cut -d' ' -f1 /proc/uptime)s"
    for r in "$RP"/remoteproc*; do
      case "$(cat "$r/name" 2>/dev/null)" in
        *mss*|*modem*) echo "modem recovery: $(cat "$r/recovery" 2>/dev/null)  ($(cat "$r/name" 2>/dev/null), $(cat "$r/state" 2>/dev/null))" ;;
      esac
    done
    echo "modem crashes in the kept logs: $(all_crash | grep $GA -cE "$CRASH_RE")"
    echo "modem crashes since install (lifetime counter): $(num "$(cat "$D/.crash_total" 2>/dev/null)" 0)"
    lastc="$(all_crash | grep $GA -E "$CRASH_RE" | tail -n 1 | cut -c1-200)"
    echo "last crash: ${lastc:-none}"
    if [ -f "$CSV" ] || [ -f "$CSV.old" ]; then
      echo "--- crashes by network type (slot1/slot2) before crash:"
      all_csv | cut -d, -f3 | sort | uniq -c | sort -rn | head -5
      echo "--- crashes by provider (slot1/slot2) before crash:"
      all_csv | cut -d, -f4 | sort | uniq -c | sort -rn | head -5
      echo "--- last crash context: $(all_csv | tail -n 1 | cut -d, -f3,4,7,8)"
    fi
    echo "SIMs: $([ "$dual_seen" = 1 ] && echo "dual (SIM guard active)" || echo "single or not detected yet (SIM guard idle)")"
    echo "SIM guard: $([ "$(cfg sim_guard)" != on ] && echo off || { if [ "$guard_blocked" = 1 ]; then echo "blocked by ROM (SIM power command refused, permission denied)"; elif [ "$guard_unsupported" = 1 ]; then echo "unsupported on this ROM (SIM power command failed or missing)"; else echo "on (problem SIM: $(cfg problem_sim))"; fi; })   fired this boot: $([ "$guard_tripped" = 1 ] && echo YES || echo no)"
    echo "SIM guard state: $guard_state (slot ${GUARD_SLOT:-none}, auto turn-on retries: $retries)"
    echo "crash-loop breaker: $([ -f "$BREAKER_FLAG" ] || [ "$(cfg breaker)" = on ] && echo ON || echo off)"
    echo "guard_ui: $(guard_ui_text)"
    echo "boot reason: $(getprop sys.boot.reason)"
    echo "boot reason history: $(getprop persist.sys.boot.reason.history)"
  } > "$PUB/SUMMARY.txt" 2>/dev/null
}

# Log EVERY new modem crash line (plus context). The last logged crash is remembered by its
# kernel timestamp (seconds + microseconds), so crashes are still found when the dmesg ring
# buffer wraps and old lines roll off. The position is also saved (with the boot id) so a
# restarted worker does not log everything again.
last_s=0; last_f=0; last_cnt=-1
BOOTID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
restore_last_ts() {   # same boot only: kernel timestamps start again from 0 after a reboot
  [ -f "$D/.last_ts" ] || return 0
  read -r b_id b_s b_f < "$D/.last_ts"
  if [ -n "$BOOTID" ] && [ "$b_id" = "$BOOTID" ]; then last_s="$(num "$b_s" 0)"; last_f="$(num "$b_f" 0)"; fi
  return 0
}
TSRE='s/^[^[]*\[ *\([0-9][0-9]*\)[.,].*/\1/p'
# turns "[  123.004567] text" into "123|4567|[  123.004567] text" (leading zeros removed, safe for shell arithmetic)
SEDTS='s/^[^[]*\[ *0*\([0-9][0-9]*\)\.0*\([0-9][0-9]*\)\].*$/\1|\2|&/p'

process_new_crashes() {  # $1 = number of lines in .new_crash, $2 = "old" when they must not count as a live crash loop
  if [ "$LOGGING" = on ]; then tot="$(num "$(cat "$D/.crash_total" 2>/dev/null)" 0)"; put "$D/.crash_total" $((tot + $1)); fi
  kn_now="$(dmesg 2>/dev/null | tail -n 1 | sed -n "$TSRE")"
  while IFS= read -r l <&3; do
    echo "$(date) $l" >> "$CRASHLOG"
    cts="$(printf '%s' "$l" | sed -n "$TSRE")"
    if [ "$2" = old ] || { [ -n "$cts" ] && [ -n "$kn_now" ] && [ $((kn_now - cts)) -gt "$BREAKER_WINDOW" ]; }; then
      echo "  (older crash, no SIM/signal context)" >> "$CRASHLOG"
    else
      log_context "$l"
    fi
    [ "$2" = old ] || note_crash "$cts" "$kn_now"
  done 3< "$D/.new_crash"
  [ "$LOGGING" = off ] && rm -f "$D/.new_crash" "$D/.tagged"   # logging off: keep no copy of kernel lines
  sync_dirty=1
  enable_recovery again   # re-apply immediately after a crash
}

save_crash_notime() {  # dmesg lines carry no timestamps: count lines instead (cannot survive a buffer wrap)
  if [ "$notime_noted" = 0 ]; then
    echo "$(date) NOTE: dmesg has no timestamps; crashes are counted by line count and some may be missed after the kernel log wraps" >> "$LOG"
    notime_noted=1
  fi
  cnt=$(( $(printf '%s\n' "$all" | wc -l) ))
  [ "$cnt" -gt "$last_cnt" ] || { last_cnt="$cnt"; return; }
  if [ "$last_cnt" -lt 0 ]; then first=old; new="$cnt"; else first=live; new=$((cnt - last_cnt)); fi
  last_cnt="$cnt"
  printf '%s\n' "$all" | tail -n "$new" > "$D/.new_crash"
  if [ "$first" = old ]; then process_new_crashes "$new" old; else process_new_crashes "$new"; fi
}

save_crash() {
  all="$(dmesg 2>/dev/null | grep $GA -E "$CRASH_RE")"
  [ -n "$all" ] || return
  newest="$(printf '%s\n' "$all" | tail -n 1 | sed -n "$SEDTS")"
  [ -n "$newest" ] || { save_crash_notime; return; }
  ns="${newest%%|*}"; nf="${newest#*|}"; nf="${nf%%|*}"
  # nothing newer than the last crash we logged: stop here, no file writes in the steady state
  [ "$ns" -gt "$last_s" ] || { [ "$ns" -eq "$last_s" ] && [ "$nf" -gt "$last_f" ]; } || return
  printf '%s\n' "$all" | sed -n "$SEDTS" > "$D/.tagged"
  [ -s "$D/.tagged" ] || return
  : > "$D/.new_crash"; got=0
  while IFS='|' read -r s f l <&4; do
    if [ "$s" -gt "$last_s" ] || { [ "$s" -eq "$last_s" ] && [ "$f" -gt "$last_f" ]; }; then
      printf '%s\n' "$l" >> "$D/.new_crash"; got=$((got+1))
    fi
  done 4< "$D/.tagged"
  [ "$got" -gt 0 ] || return
  last_s="$ns"; last_f="$nf"
  put "$D/.last_ts" "$BOOTID $last_s $last_f"
  process_new_crashes "$got"
}

# Two independent loops that also watch each other, so a slow Android call can never delay
# re-applying recovery and neither loop can die unnoticed:
#  - the recovery loop only re-applies recovery every second (and restarts the worker if it dies);
#  - the worker does the slow things: crash scan, SIM/signal sampling, SIM guard, log sync
#    (and restarts the recovery loop if it dies).
# Restarts are capped (10 per loop per boot) so a broken environment can never cause a respawn storm.
PIDW="$D/.pid_work"; PIDR="$D/.pid_rec"; rest_w=0; rest_r=0
pid_alive() { p="$(cat "$1" 2>/dev/null)"; case "$p" in ''|*[!0-9]*) return 1;; esac; kill -0 "$p" 2>/dev/null; }
already_running() {  # a live module process (not a reused pid) is named in both pid files
  for f in "$PIDW" "$PIDR"; do
    p="$(cat "$f" 2>/dev/null)"; case "$p" in ''|*[!0-9]*) return 1;; esac
    kill -0 "$p" 2>/dev/null && grep $GA -q "modem_recovery_enable" "/proc/$p/cmdline" 2>/dev/null || return 1
  done
  return 0
}
check_rec_loop() {
  pid_alive "$PIDR" && return
  [ "$rest_r" -lt 10 ] || return
  rest_r=$((rest_r+1))
  echo "$(date) WARN: recovery loop stopped, restarting it" >> "$LOG"
  recovery_loop & echo $! > "$PIDR"
}
worker_loop() {
  SG_PREV="$(cat "$D/.sg_last" 2>/dev/null)"   # a restarted worker must not see an old value
  ensure_config
  load_resume
  restore_last_ts
  snapshot   # learn SIM/network state first, so crashes already in dmesg get their context
  SCAN_SLEEP=$((SCAN_EVERY * TICK))
  while true; do
    cfg_load; sync_auto_on; set_logging; purge_logs
    scan_needed && save_crash
    snapshot; guard_deferred; guard_tick; guard_resume; airplane_flag_check; write_guard_ui; sync_logs
    check_rec_loop
    sleep "$SCAN_SLEEP"
  done
}
recovery_loop() {
  mode=first; tick=0
  while true; do
    enable_recovery "$mode"
    mode=again
    tick=$((tick+1))
    if [ "$tick" -ge 30 ]; then
      tick=0
      if ! pid_alive "$PIDW" && [ "$rest_w" -lt 10 ]; then
        rest_w=$((rest_w+1))
        [ -f "$D/.logging_off" ] || echo "$(date) WARN: worker loop stopped, restarting it" >> "$R_LOG"
        worker_loop & echo $! > "$PIDW"
      fi
    fi
    sleep "$TICK"
  done
}

# Boot diagnostics: why did the previous boot end? Runs once per boot, as soon as logging is on
# (at start, or later when logging is switched on).
boot_diag() {
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  [ -f "$D/.logging_off" ] && return   # logging was switched off while waiting: write nothing
  {
    echo "=== $(date) boot completed, uptime $(cut -d' ' -f1 /proc/uptime)s ==="
    echo "sys.boot.reason=$(getprop sys.boot.reason)"
    echo "ro.boot.bootreason=$(getprop ro.boot.bootreason)"
    echo "persist.sys.boot.reason.history=$(getprop persist.sys.boot.reason.history)"
    echo "pstore files:"; ls -l /sys/fs/pstore 2>/dev/null
    for f in /sys/fs/pstore/console-ramoops*; do
      [ -f "$f" ] && { echo "-- tail of $f"; tail -n 60 "$f"; }
    done
  } >> "$BOOTLOG" 2>&1
}
run_boot_diag() {
  [ -f "$D/.bootdiag_done" ] && return
  : > "$D/.bootdiag_done"
  boot_diag &
}
already_running && exit 0   # a second start (manager re-run) must not create a second set of loops
rm -f "$D/.bootdiag_done" 2>/dev/null
cfg_load; set_logging; ensure_config; set_logging
[ "$LOGGING" = on ] && run_boot_diag
rotate
echo "=== $(date) service start, uptime $(cut -d' ' -f1 /proc/uptime)s ===" >> "$LOG"
recovery_loop & echo $! > "$PIDR"   # recovery first: it is the part that must never wait
worker_loop & echo $! > "$PIDW"
