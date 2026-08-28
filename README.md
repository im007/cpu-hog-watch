# cpu-hog-watch

Desktop alerts for Linux when a single process pegs a CPU core, with a
button to stop it. Built for people whose laptop fans spin up for hours
because one runaway browser tab is burning a thread.

On a 16-thread CPU, one saturated thread is **6.25% system-wide** — far
below the threshold of any system-wide monitor. This samples each
process separately and scales to *one core*, so that thread reads 99%
instead of 6%. The blind spot widens as core counts rise: on 32 threads
the same process is 3%.

## What you get

- **A per-process watcher.** Alerts when one process holds a core for a
  sustained period, and offers to stop it.
- **A thermal backstop.** A second, independent alert for heat with no
  single process behind it — a GPU, firmware, a root daemon.
- **Alerts that persist.** Popups stay until dismissed, and repeat if
  the process is still misbehaving later.
- **A guarded kill.** The target is verified by PID *and* start time, so
  a recycled PID cannot be killed by mistake.
- **No daemon.** A systemd user timer samples every 60 seconds.

## Requirements

| Need | Detail |
|---|---|
| OS | Linux with systemd and a graphical user session |
| Shell | bash 4+ |
| Packages | `libnotify` (`notify-send`) |
| Desktop | Any notification daemon; tested on KDE Plasma 6 (Wayland) |

## Quick start

```
git clone https://github.com/im007/cpu-hog-watch.git
cd cpu-hog-watch
./install.sh
```

This links the scripts into `~/.local/bin`, writes a default config to
`~/.config/cpu-hog-watch.env`, installs a systemd user timer, and starts
it.

Keep the clone. `install.sh` symlinks rather than copies, so `git pull`
updates the live tool — and deleting the directory breaks the install.

Check what it found on your hardware:

```
cpu-hog-watch --detect
```

To remove it (the config file is left alone):

```
./install.sh --uninstall
```

## Sensor detection

Temperature is probed in order, first match winning:

| Probe | Hardware |
|---|---|
| `k10temp` / `Tdie` | AMD, real die temperature |
| `k10temp` / `Tctl` | AMD, control value; always present |
| `zenpower` / `Tdie` | AMD, out-of-tree driver |
| `coretemp` / `Package id 0` | Intel, Sandy Bridge and newer |
| `coretemp` / `Physical id 0` | Intel, where the label differs |
| `cpu_thermal` | ARM SoCs |
| `acpitz*` | Generic ACPI zone, last resort |

`Tdie` is tried before `Tctl` because it is the real measured die
temperature; `Tctl` is a control value on an arbitrary scale that drives
fan curves and does not represent a physical temperature.

Fans need no list. Any hwmon exposing `fan*_input` is a fan controller,
and the fastest one is used.

Override either with `THERM_HWMON`, `THERM_LABEL` and `FAN_HWMON` if
detection picks wrong.

## What an alert looks like

A single process holding a core gets a popup naming it:

> **cpu-hog-drill · 99% of a core**
> Held for **12 min** — PID 331948
> CPU 94 °C · fan 5228 RPM
>
> `Stop it`  `Leave it`

Heat with no single process behind it gets the backstop alert, which
lists what is actually running hot:

> **Fan pinned at 5228 RPM**
> Sustained **~15 min** · CPU 94 °C
>
> **Top CPU users**
> 91% cpu-hog-drill
> 38% Isolated Web Co
> 37% zen-bin
>
> `Stop cpu-hog-drill`  `Leave it`

The backstop offers a kill button only when one process is clearly to
blame. Otherwise there is nothing sensible to point it at.

## Stopping a browser tab

Stopping a browser content process ends **that tab**, not the browser.
Your session, your window and your other tabs keep running, and the dead
tab shows a **Restore This Tab** button.

The unit is the content process rather than the tab itself. Under
Firefox's Fission — its site-isolation model — one process serves one
site, so two tabs on the same site can share a process, and one tab with
cross-origin frames can span several.

That restore page also tells you *which* tab it was. A tab's address is
known only to the parent browser process, so it cannot be read from the
content process's `/proc` entry.

## Configuration

All settings are optional and live in `~/.config/cpu-hog-watch.env`.
The file holds no secrets.

| Setting | Default | Meaning |
|---|---|---|
| `HOG_PCT` | `85` | Percent of **one core** that counts as pegged |
| `HOG_STRIKES` | `10` | Consecutive 60s samples before alerting |
| `HOG_RENOTIFY` | `30` | Samples before repeating an alert |
| `HOG_ALLOW_RE` | compilers, ffmpeg, … | Regex of processes allowed to peg a core |
| `HOG_KILL_BUTTON` | `true` | Set `false` for notify-only |
| `THERM_C` | `92` | Backstop temperature, °C |
| `THERM_STRIKES` | `5` | Samples above `THERM_C` before alerting |
| `FAN_RPM` | `4500` | Backstop fan speed, RPM |
| `FAN_STRIKES` | `15` | Samples above `FAN_RPM` before alerting |
| `THERM_HWMON` | `auto` | hwmon device for temperature, or `auto` |
| `THERM_LABEL` | *(empty)* | Temperature label to match, with an explicit device |
| `FAN_HWMON` | `auto` | hwmon device for fan speed, or `auto` |

**If alerts get noisy, raise `HOG_STRIKES` before anything else.** Alert
fatigue kills a monitor faster than a missed event does. Add genuinely
CPU-hungry tools to `HOG_ALLOW_RE`.

`claude` is deliberately absent from the default allowlist — a Claude
process holding a core for ten minutes is worth knowing about.

## Commands

| Command | Does |
|---|---|
| `cpu-hog-watch` | Take one sample; the timer calls this |
| `cpu-hog-watch --status` | Thresholds, live readings, anything striking |
| `cpu-hog-watch --detect` | Which sensors were found, chosen, and rejected |
| `cpu-hog-watch --dry-run` | Detect and log, but never notify or kill |
| `cpu-hog-watch --help` | Usage |
| `install.sh --verify` | Check a live install |
| `install.sh --uninstall` | Remove it, keeping the config |

## Limitations

What this deliberately does not do.

- **Linux with systemd and a graphical login only.** The alert is a
  desktop notification, so there must be a session to show it in.
- **It watches only your own processes.** A desktop session cannot
  signal a root process, so a runaway system daemon raises no
  per-process alert. The thermal backstop is what covers that case,
  since heat is measured regardless of who owns the cause.
- **The thermal backstop depends on hardware sensors.** Detection is
  automatic and covers AMD, Intel and ARM, but a machine exposing none
  of them gets no backstop. `cpu-hog-watch --detect` states plainly
  what was found; `install.sh --verify` warns if nothing was.
- **A generic ACPI zone is a fallback, not a measurement.** Where no
  vendor sensor exists, detection falls back to `acpitz`, which may
  report skin or chassis temperature rather than the CPU. Both
  `--detect` and `--status` label it when this happens.
- **It reacts, it does not prevent.** Nothing is throttled or capped;
  you are told, and you decide.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| No alerts ever | `systemctl --user status cpu-hog-watch.timer` |
| No thermal alerts | `cpu-hog-watch --detect` — nothing found means no backstop |
| Temperature looks wrong | Detection landed on a generic zone; set `THERM_HWMON` |
| Alerts too frequent | Raise `HOG_STRIKES`, or extend `HOG_ALLOW_RE` |
| Popups never appear | The timer must be a **user** unit; a system unit has no session bus |
| Want more detail | `SCRIPT_DEBUG=true cpu-hog-watch` |
| Trace one process | `CPU_HOG_TRACE_PID=<pid> SCRIPT_DEBUG=true cpu-hog-watch` |

Logs go to the journal:

```
journalctl --user -u cpu-hog-watch -f
```

## How it works

A systemd user timer runs every 60 seconds. Each run reads
`utime + stime` from `/proc/PID/stat` for every process the user owns,
diffs against the previous sample, and scales the result to one core.
Elapsed time comes from total jiffies in `/proc/stat` rather than the
clock, so suspending the machine cannot register as a spike.

State lives in `$XDG_RUNTIME_DIR/cpu-hog-watch/state`, keyed on
`PID:starttime`. After `HOG_STRIKES` consecutive breaches the watcher
launches the popup as its own transient systemd unit, which lets the
popup outlive the timer run that produced it.

Sensor discovery lives in `cpu-hog-lib.sh`, shared by the watcher and
the notifier so the two cannot disagree about how heat is measured.

<details>
<summary><b>Design notes</b> — why parts of this look the way they do</summary>

- **CPU count comes from `/proc/stat`, not `nproc`.** `nproc` honours
  the cgroup CPU quota, so inside a unit with `CPUQuota=50%` it returns
  `1` on a 16-thread host. That scales every reading by 1/16 and a
  pegged core reads 6%. Counting `^cpu[0-9]` lines in `/proc/stat` keeps
  the numerator and denominator from disagreeing.

- **Per-process CPU is measured by diffing `/proc/PID/stat`, never with
  `ps %cpu`.** `ps` reports an average over the process's whole
  lifetime, so a process that starts misbehaving reads far below its
  current rate. It also ranks itself near the top of its own snapshot.

- **The `comm` field holds spaces and parentheses**, as in
  `(Isolated Web Co)`. Field numbering with `awk $14/$15` reads the
  wrong columns; the parser strips through the **last** `') '` first.

- **hwmon devices are resolved by their `name` file**, and the generic
  probe matches a prefix. The numbering under `/sys/class/hwmon` is not
  stable across boots, and machines expose `acpitz_0`, `acpitz_1` and so
  on rather than a bare `acpitz`.

- **State entries are counted with an integer.** Reading `${#array[@]}`
  on an empty bash associative array raises an unbound-variable error
  under `set -u`.

- **The popup runs as a transient unit via `systemd-run --user`.** A
  `setsid` child would remain in the timer service's control group and
  be terminated as soon as `ExecStart` returned.

- **The unit sets `ReadWritePaths=%t`** because `ProtectSystem=strict`
  would otherwise make `/run` read-only, where the state file lives.

- **Counters use `x=$((x+1))`.** The `((x++))` form returns non-zero
  when the result is 0, which trips `set -e`.

</details>

## License

[AGPL-3.0-or-later](LICENSE).

**The obligation comes first: if you distribute a modified version — or
run one as a network service — you must release your source under this
same licence.** That network clause is what distinguishes AGPL from
plain GPL, and it is the part most people miss.

**Everything else is permitted, commercial use included.** AGPL does not
bar selling this or running it for profit. What it requires is
reciprocity, not permission.
