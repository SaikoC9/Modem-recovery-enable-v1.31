#!/system/bin/sh
# Runs when the module is removed (early in the next boot). Cleans up everything
# the module created and turns a SIM back on / airplane mode back off if the module changed them. Storage and telephony
# are not ready that early, so the work happens in the background after boot.
D="${LOG_DIR:-/data/local/tmp}"
PUB_BASE="${PUB_BASE:-/sdcard}"
(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 2; done
  sleep "${UNINSTALL_DELAY:-20}"
  n=0
  while [ ! -d "$PUB_BASE/Android" ] && [ "$n" -lt 60 ]; do sleep 2; n=$((n+1)); done

  if [ -f "$D/.sim_off_sub" ]; then
    sub="$(cat "$D/.sim_off_sub" 2>/dev/null)"
    case "$sub" in ''|*[!0-9]*) ;; *) cmd phone enable-physical-subscription "$sub" >/dev/null 2>&1 ;; esac
  fi
  if [ -f "$D/.airplane_by_module" ]; then
    cmd connectivity airplane-mode disable >/dev/null 2>&1 || {
      settings put global airplane_mode_on 0
      am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
    }
  fi

  # Settings (root-only) and the logs in Internal storage are deleted by default; purge_on_uninstall=no keeps them.
  CFG_DIR="${CFG_DIR:-/data/adb/modem_recovery_enable}"
  # Default is to purge: only an explicit purge_on_uninstall=no keeps them.
  if [ "$(sed -n 's/^purge_on_uninstall=//p' "$CFG_DIR/config.txt" 2>/dev/null | tail -n 1 | tr -d '\r ')" != no ]; then
    rm -rf "$PUB_BASE/ModemRecoveryLogs" "$CFG_DIR"
  fi

  rm -f "$D"/modem_recovery.log* "$D"/modem_crash_reasons.log* "$D"/modem_crash_context.log* \
        "$D"/modem_crash_table.csv* "$D"/last_boot_info.log* "$D"/modem_breaker_on \
        "$D"/.new_crash "$D"/.tagged "$D"/.last_ts "$D"/.crash_total "$D"/.sim_off_slot "$D"/.sim_off_sub "$D"/.airplane_by_module "$D"/.guard_ui "$D"/.logging_off "$D"/.logs_purged "$D"/.sg_last "$D"/.bootdiag_done "$D"/.pid_work "$D"/.pid_rec
) >/dev/null 2>&1 &
exit 0
