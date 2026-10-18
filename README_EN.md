# VPS Bootstrap Script (v9.9 Eternal Guard Edition)

<p align="center">English ｜ <a href="README.md">简体中文</a></p>

> Supported systems: Debian 10+ / Ubuntu 20+ / Alpine Linux 3.15+

## Core features

1. **Network**: enables BBR congestion control with FQ queueing for higher throughput and lower latency
2. **Memory**: deploys a zRAM compressed swap device to raise the effective memory ceiling
3. **Containers**: installs / updates / uninstalls Docker Engine and the Compose plugin
4. **Timezone**: sets the system timezone to Asia/Shanghai
5. **Guard**: weekly automatic cleanup of system caches, logs, and container junk so the disk never fills up
6. **Cleanup**: runs a one-off system cleanup immediately

## 🚀 One-liner

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BeacherZ/vps99.sh/main/vps99.sh)
```

---

## Module reference

The script is modular: once started you choose which tasks to run.

### Environment detection

- Detects Debian / Ubuntu / Alpine and prints distro name + version
- Collects a hardware summary in a single line: cores · CPU model · memory · disk size
- Detects a Proxmox VE (PVE) host and downgrades the cleanup strategy accordingly
- Detects the current state of each module (green = ready, yellow = not configured)

### Network algorithm - BBR+FQ

- Defaults to N; explicit confirmation required
- Configures BBR congestion control and the FQ queue discipline together
- Writes through a `sysctl_set` helper so lines are never duplicated and spacing variants in config files are tolerated
- Verifies the result automatically; usually effective immediately, otherwise it prompts for a reboot

### Memory optimization - zRAM

- Defaults to N; explicit confirmation required
- zRAM size: 100% of RAM when RAM ≤ 1 GB; 60% when RAM > 1 GB
- Adaptive swappiness: 60 when a physical swap exists; zRAM-only hosts use 80 on small memory, 60 on larger memory
- lz4 compression, priority 100 (above disk swap)
- Uses `--force-confold` during install to avoid dpkg config prompts blocking the run
- Requires a reboot to take effect

### Container deployment - Docker

- Defaults to N; answer y to open the submenu
- Queries the GitHub API for the latest Docker and Compose versions (5s timeout; skips the update check on failure)
- When already installed, shows a version comparison: up to date / update available to x.x.x
- Up to date: menu shows only `1) Uninstall  2) Skip`
- Update available: menu shows `1) Update  2) Uninstall  3) Skip`
- Not installed: menu shows `1) Install  2) Skip`
- Skips the 20s wait inside Docker's official install script
- The install script download has a 60s timeout and reports failures explicitly (never a false success)
- Repairs a stuck dpkg lock before installing
- Verifies and prints the actual installed version afterwards
- ⚠️ **Uninstall wipes `/var/lib/docker` and `/var/lib/containerd` — handle with care**

### System timezone

- Defaults to N; explicit confirmation required
- Checks the current timezone and reports that nothing is needed when it is already Asia/Shanghai
- Installs the tzdata package automatically on Alpine

### Storage guard - scheduled cleanup

- Defaults to N; explicit confirmation required
- Deploys `/root/vps99clean.sh` as a cron job that runs every Monday at 06:06
- Debian/Ubuntu: repairs the dpkg lock + deep apt clean + keeps journalctl to 7 days + caps logs at 100M
- Alpine: truncates files under `/var/log` and clears the apk cache and temp files
- Docker: removes every image not used by a container (including dangling ones) + truncates container logs
- PVE protection: skips `pkill apt/dpkg` and `journalctl --vacuum-time`, only caps logs at 100M
- Uses `--force-confold` so unattended cron runs never hang

### Immediate cleanup

- Defaults to Y (the only option enabled by default)
- Runs the same cleanup logic as the scheduled job
- Prints progress while it works

---

## Common management commands

| Purpose | Command |
|------|----------|
| Inspect the scheduled cleanup job | `crontab -l` |
| Run the cleanup manually | `/root/vps99clean.sh` |
| Check memory compression | `zramctl` |
| Check BBR status | `sysctl net.ipv4.tcp_congestion_control` |
| Check FQ status | `sysctl net.core.default_qdisc` |
| Detect whether this is PVE | `command -v pveversion` |
| Check Docker versions | `docker -v && docker compose version` |
| Check the system timezone | `cat /etc/timezone` |
| Check swappiness | `cat /proc/sys/vm/swappiness` |

---

## Important notes

**Reboot required**: after choosing BBR+FQ or zRAM the script verifies the result immediately. BBR+FQ usually applies at once; a first-time zRAM deployment normally needs a reboot. If you skip everything, no reboot is needed.

**Safe cleanup**: on Alpine the script uses `truncate` to empty log files while keeping the files and directory structure, so services like nginx will not crash because their log directory disappeared.

**PVE compatible**: the script detects a Proxmox VE host via `command -v pveversion` and then skips `pkill apt/dpkg` and `journalctl --vacuum-time`, performing only safe cache cleanup and a 100M log cap so host stability is unaffected.

**Conservative by default**: every module defaults to N except the immediate cleanup. Each choice prints a green result line right after it runs.

**Color scheme**: green = ready / succeeded, yellow = not configured / skipped, red = failed.

**Long-term guard**: once the cron job is deployed it keeps cleaning weekly for as long as the system is not reinstalled. The cleanup script also detects PVE internally, so it adapts on any machine you copy it to.

---

## Aliyun CDT 1G disk edition

A dedicated build for **Aliyun CDT instances with a 1G system disk** (or any system disk ≤ 2G). Compared with the general build, **only the cleanup module differs**; every other module (BBR / zRAM / Docker / timezone / reporting / interactive UI) is identical line for line.

### 🚀 One-liner

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BeacherZ/vps99.sh/main/vps99-1g.sh)
```

### Differences from the general build

| Item | General build | 1G edition |
|------|--------|----------|
| journalctl cap | 7d + 100M | **10M** |
| Deep cleanup | none | **doc / man / consolefonts / i18n / terminfo / locale / firmware / pycache** |
| aliyun-assist | untouched | **keeps only the newest version directory, deletes old ones** |
| Cleanup sub-script | `/root/vps99clean.sh` | `/root/vps99clean-1g.sh` |

### Why it exists

Aliyun images ship two copies of `aliyun-assist` (old + new), and leftovers from journal, doc, man and friends push a fresh install from 400M to over 500M. The 1G edition deep-cleans exactly these items.

### Switching from the general build to the 1G edition

Clear the old cron entry and sub-scripts first, then run the new script:

```bash
crontab -l 2>/dev/null | grep -v 'vps99clean' | crontab -
rm -f /root/vps99clean.sh /root/vps99clean-1g.sh
```

### aliyun-assist safety

The script deletes only old version directories and keeps the newest version plus its symlink. Shutdown/reboot, cloud monitoring, and Cloud Assistant command delivery from the Aliyun console are unaffected.

### Recommendation

**Use the general build with a disk ≥ 2G; use the 1G edition on Aliyun CDT 1G system disks.**
