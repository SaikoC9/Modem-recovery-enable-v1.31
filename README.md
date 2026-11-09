# Modem Recovery Enable

A KernelSU / Magisk module for Qualcomm phones. It keeps the modem (`mss`) remoteproc **recovery** enabled from early boot, so a modem crash restarts the modem instead of rebooting the whole phone. It also logs every modem crash with SIM, network and signal context, and shows a status page (WebUI).

## Install

1. Open KernelSU Next (or Magisk) and install the zip as a module.
2. **Reboot once.** The manager only shows the module and its Open button after a reboot.
3. Tap **Open** on the module card to see the status page.

The status page is a KernelSU feature. On Magisk, open it with a WebUI app (for example MMRL or WebUI X); everything else works the same.

## Requirements

- Qualcomm phone with root (KernelSU, KernelSU Next or Magisk 20.4+).
- A kernel that exposes `recovery` for the modem. Check:
  `su -c "grep -H . /sys/class/remoteproc/*/name"` and look for a name containing `mss` or `modem`.
- Dual-SIM guard needs Android with `cmd phone disable-physical-subscription` (tested on Android 17), and a ROM that allows that command. Some ROMs list it but refuse it; see Known limitations.

## What it does

- Re-applies `recovery=enabled` on the modem every second (every 0.2 s for the first ~20 s of boot), in its own loop so a slow Android service can never delay it.
- Logs every modem crash (`fatal error received` / `watchdog received`) with the last SIM, network type and signal sample.
- Status page: crash counts, a Protection card (recovery value, service, SIM guard, last boot reason), a crashes-per-10-minutes chart, the airplane breaker switch and a Settings card.
- Logs are copied to `Internal storage/ModemRecoveryLogs` when logging is switched on (off by default).
- **SIM guard (dual SIM only, optional, off by default):** turn it on with `sim_guard=on`. After 3 modem crashes in 2 minutes it powers down only the problem SIM and turns it back on when the other SIM's signal is strong. Single SIM: never runs. If the ROM refuses the SIM power command, the guard stops for that boot and the status page says **Blocked by ROM**.
- **Airplane breaker (off by default):** after 5 crashes in 2 minutes it turns airplane mode on. It never turns it off by itself, except when you uninstall the module, and only if the module turned it on and you have not turned it off since.

## Settings

Change them in the status page (**Settings** card, then **Save settings**), or edit the root-only file `/data/adb/modem_recovery_enable/config.txt` as root. Apps cannot read or change that file. While logging is on, `ModemRecoveryLogs/config_readonly.txt` is a read-only copy; edits to it are ignored. With logging off the folder does not exist.

```
logging=off
sim_guard=off
problem_sim=YourProvider
breaker=off
auto_on=off
retry_minutes=10
stable_minutes=5
strong_rsrp=-100
max_retries=3
purge_on_uninstall=yes
```

**Logging switch (off by default):** with `logging=off`, the default, the module writes no log, crash, CSV, summary or dmesg file and copies nothing to storage. Turn on **Save logs to storage** in Settings (`logging=on`) to keep logs in `Internal storage/ModemRecoveryLogs`. A config with no `logging` line counts as off. With logging off, the status page crash counts, chart and last-crash line stay empty, because nothing is recorded; turn logging on first if you want crash history or logs to share. Switching logging from on to off deletes the `ModemRecoveryLogs` folder and the saved logs (the Settings card asks first). Recovery always runs. The SIM guard and airplane breaker, when switched on, still read the kernel log in memory to see crashes. With both off (the defaults) the module does not read the kernel log at all.

**To use the SIM guard,** set `sim_guard=on` (this also sets `auto_on=on`; `auto_on` follows `sim_guard` and only matters while the guard is on) and set `problem_sim` to part of your provider's name (as shown in the status bar). While `problem_sim` still says `YourProvider`, the guard stays idle.

## Disclaimer

Use this module at your own risk. It changes low-level modem and SIM settings on a rooted phone. It is provided "as is", without any warranty. The author is not responsible for any damage, data loss, lost service, extra charges or other problems that come from installing or using it.

## Known limitations

- **This does not fix a broken modem.** If the modem firmware itself crashes (for example `err_decompress ... inf_out overflowed` or `rflm_txagc_lookup_opt ... Assertion`), the module only keeps the phone from rebooting on those crashes. Flashing the modem firmware that matches your ROM is the real fix (mine not, so i create this).
- It cannot prevent a full reboot caused by something other than the modem (kernel panic, another subsystem such as adsp/cdsp/wpss). Crash messages from another remoteproc subsystem are also counted.
- **The SIM guard may not work on your ROM.** i tested on in a real crash loop, the guard fired and found the right SIM, but `cmd phone disable-physical-subscription` was refused with "Permission denied" for root, shell, system and radio users, with no SELinux denial in the logs. Modules cannot get around that. In that case the guard stops and says **Blocked by ROM**; switch the problem SIM off by hand in Settings > SIM manager. Where the ROM allows the command, the power-down path has only been tested with a mock, not on a real phone. Leave `breaker=off` and consider `sim_guard=off` for unattended daily use.
- The logs in `ModemRecoveryLogs` are readable by any with storage access. Settings are not.
