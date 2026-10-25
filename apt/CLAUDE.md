# apt

Unattended **security** upgrades on all twelve enrolled hosts, and the metrics
that say whether they are still happening.

One directory rather than twelve, because this is one concern replicated — the
same shape as `node-exporter/` and `alloy/`, and the same exception to the
one-directory-per-container rule.

It is **not** in `fleet/`, which is the other home it could have had.
`fleet/CLAUDE.md` is explicit that it has no `root/` tree: it asserts state and
pushes nothing. This pushes four files and installs two packages, so it would
have broken that shape rather than fitting into it.

## Why this exists at all

The question that started it was whether a local apt cache would save
bandwidth. It would not — twelve minimal Debian hosts on a stable release pull
tens of MB of security updates a month between them, which is nothing against a
fibre line, and the real traffic is Docker image pulls on moby, which an apt
proxy does not touch. What was actually missing was not a cache but *any*
automatic patching, and any way to tell that a host had stopped.

So: no proxy, no mirror, no cache. A timer per host, and four metrics.

## Working on this

`root/` mirrors the host filesystem and is the source of truth; the same four
files go to every host.

```sh
./scripts/verify.sh                 # is the fleet patched, and still patching?
./scripts/deploy.sh                 # apply everywhere
./scripts/deploy.sh 192.168.8.52    # just one host, after rebuilding it
```

The host list is read out of `ca/scripts/enrol.sh`, not copied here — the same
reasoning as `fleet/`, which already refuses to keep a fourth copy.

Independent of every other deploy order, with one dependency: the textfile
drop-box that `node-exporter/scripts/deploy.sh` creates. Deploy refuses without
it rather than publishing metrics nothing will scrape.

**Deploy here before `grafana/`, and not the other way round.**
`apt-not-patching` has `noDataState: Alerting` — which is correct, because a
host that publishes nothing cannot be said to be patched — so provisioning the
`apt` group while any host is still missing the metric fires it on the phone
for every one of them. Finish the fleet first, then deploy `grafana/`.

## Invariants — do not "simplify" these away

1. **The package's own `20auto-upgrades` and `50unattended-upgrades` are left
   alone.** Everything is in `52homelab-unattended-upgrades`, read after both.
   They are dpkg conffiles: a copy of them here would mean re-merging on every
   package upgrade and a prompt on a file we had rewritten.

2. **`#clear Unattended-Upgrade::Origins-Pattern;` comes before the pattern,
   and it is the most important line in the file.** apt config *lists append* —
   defining `Origins-Pattern` in a later file adds to what
   `50unattended-upgrades` already set rather than replacing it, so without the
   clear the package's defaults stay active alongside ours and the origin list
   is not what this directory says it is. `deploy.sh` and `verify.sh` both
   assert the list has exactly one entry, which is how that is caught.

3. **Security origin only, and what it excludes is the safety mechanism.** Not
   a conservative default to be relaxed later:

   - **lenora**: `pve-*` comes from the Proxmox repo, origin `Proxmox`, so
     Proxmox upgrades stay a deliberate manual act. The host carries every
     container in the lab.
   - **moby**: `docker-ce` comes from `download.docker.com`, origin `Docker`.
     An unattended docker upgrade restarts the daemon and every stack with it.
   - **hermes**: mailcow is Docker images driven by its own `update.sh`
     (`hermes/CLAUDE.md`), not apt, so nothing here touches it.

   It excludes two more things worth naming: `alloy` on every host, which comes
   from `apt.grafana.com`, and **Debian's own stable point releases**. The
   security archive and `stable` are different archives — 13 of pythia's 52
   pending upgrades on 25 October 2026 were security, the other 37 were the
   13.7 point release. Those 37 will sit there until someone runs `apt upgrade`
   by hand; they show as `apt_upgrades_pending{origin="other"}` and nothing
   alerts on them, deliberately. If that drift becomes the thing you dislike,
   the honest fix is adding `origin=Debian,codename=${distro_codename}` to the
   pattern — still Debian-only, still no Proxmox or Docker — not loosening the
   alert.

   Widening this to `-updates`, backports or a third-party origin is how all
   three stop being true.

   **The `-security` suffix in the pattern is load-bearing and looks like a
   typo.** `security.debian.org`'s Release carries `n=trixie-security`, so
   `codename=${distro_codename}` — the form Debian itself still ships, for
   compatibility with pre-bullseye naming — matches nothing and would patch
   zero packages while reading as correct. This was written the wrong way first
   and caught by checking `apt-cache policy` on a real host rather than by
   anything failing.

4. **Nothing is restarted or rebooted unattended, and that gap is monitored
   rather than closed.** `Automatic-Reboot` is false, `needrestart` is
   installed in list-only mode (`$nrconf{restart} = 'l'`), and both facts are
   published as metrics: `apt_reboot_required` and
   `apt_services_need_restart`. A replaced `libssl` leaves every running
   process on the old copy, so *installed* is not *effective* — the alert says
   so after a week and repeats until someone acts. Setting needrestart to `a`
   would close the gap by restarting services mid-run on twelve hosts, which is
   the one thing this directory refuses to do on a timer.

5. **The DNS stack shares a randomised upgrade window with everything else, by
   choice.** `apt-daily-upgrade.timer` has a 60-minute randomised delay, so a
   `dnsdist` or `pdns-recursor` security upgrade can restart themis and delphi
   in the same hour. Per-host `OnCalendar` drop-ins would stagger them, at the
   cost of host-specific files in a directory that otherwise treats all twelve
   identically. Themis failing over to Delphi is designed behaviour, `dns/`
   already treats a few seconds of LAN DNS as acceptable, and
   `dns-component-down` in `grafana/` reports it if that judgement was wrong.
   Revisit the judgement before adding the drop-ins.

## Metrics

`homelab-apt-textfile` runs hourly and writes `apt.prom` into
`/var/lib/node_exporter/textfile`, so it is scraped by the existing `node` job
with the host's own labels. **Nothing was added to `prometheus.yml` for this** —
that is the whole argument for the textfile collector.

| Metric | Means |
|---|---|
| `apt_upgrades_pending{origin="security"\|"other"}` | what `apt-get -s upgrade` would install, classified by the archive in each `Inst` line |
| `apt_periodic_stamp_seconds{stamp="…"}` | when apt last updated its lists / last ran unattended-upgrades. **0 means never**, published deliberately so the age alert fires rather than going NoData |
| `apt_reboot_required` | a kernel was replaced. In practice lenora only: a container installs no kernel |
| `apt_services_need_restart` | `needrestart -b`, counting services on replaced libraries |

The narrative half lives in Loki, not here: `SyslogEnable` is on, so what was
patched is in `{host="<name>"}` via `alloy/`. The metrics say how much and how
long ago; they do not say what.

Four alerts in `grafana/`, group `apt`, in `apt.yaml`. The one that justifies
the directory is **`apt-security-pending`**: it catches an update apt will not
take unattended — a conffile question, a phased update, a held package — which
is the difference between "the timer ran" and "the job got done".

## Not done

- **No dashboard panel.** The four alerts cover it; `homelab-fleet` is
  hand-written JSON and a table of pending counts was not worth the risk of
  breaking it in passing.
- **Nothing for the router.** OpenWrt is not Debian, has no apt and cannot run
  node-exporter (`router/CLAUDE.md`), so its firmware remains a manual job.
- **The containers' `/etc/apt/sources.list` is untouched.** Mirror choice is
  whatever the Proxmox template shipped with.

## Verified

Checked on real hosts before any of this was deployed, because two of the four
assumptions behind it were wrong:

- **`apt-config dump --no-empty --format "%v%n" <list key>` prints one line per
  entry**, and two `-o Unattended-Upgrade::Origins-Pattern::=` flags produce two
  lines — so apt config lists do append, and the assertion in `deploy.sh` that
  there is exactly one entry does detect a missing `#clear`. (pythia)
- **The origins pattern was wrong**, as above: `codename=${distro_codename}`
  against a security archive whose Codename is `trixie-security`.
- **The `Inst` line's first field is the Label**, so classifying on
  `Debian-Security` is right: pythia reported
  `Debian-Security:13/stable-security` for 13 packages and
  `Debian:13.7/stable` for 37.
- **`/var/lib/apt/periodic/` is empty on a host that has never run the timers**,
  which is why an absent stamp publishes 0 rather than being omitted.
- **`unattended-upgrade --dry-run` advances the stamp**, which was the third
  thing wrong: the validation step in `deploy.sh` was quietly resetting the very
  clock the alert reads, so deploying to a host that had never patched was
  enough to make it look freshly patched. `deploy.sh` now saves the stamp's
  mtime around the dry-run and puts it back, removing the file again if it did
  not exist. Found by watching `apt_periodic_stamp_seconds` move on a host whose
  pending count had not.
- **The fleet was behind on security updates when this was written** — 13
  pending on pythia, 2 on lenora, on 25 October 2026. Nothing had been applying
  them, which is the gap this directory closes.

Then the whole loop was watched happen on pythia, 25 October 2026:
`apt-daily-upgrade.service` installed 19 security updates — `openssl`,
`libssl3t64`, `nginx`, `postfix` among them — the log recorded `Allowed origins
are: origin=Debian,codename=trixie-security,label=Debian-Security`, which is
the substituted form proving invariant 3, the stamp advanced,
`apt_upgrades_pending{origin="security"}` went 19 → 0, and Prometheus had all
six series under `role=pythia` on the next scrape. `pdns` kept answering on
`192.168.8.52` throughout, no unit failed, and the 35 point-release upgrades
were left alone exactly as intended.

**`apt_services_need_restart` went to 12 on that one upgrade**, which is
invariant 4 doing its job rather than a fault: `pdns`, `nginx`, `ssh`,
`systemd-journald` and eight others are running against the `libssl` that was
replaced underneath them. Nothing here will restart them.

`apt_periodic_stamp_seconds{stamp="update-success"}` stays 0 until
`apt-daily.service` has run once — the stamp is written by apt's own daily job,
not by `apt-get update`. No alert reads it, so that is cosmetic, but do not read
a 0 there as a fault.

Then the fleet, the same afternoon. **Every host reached
`apt_upgrades_pending{origin="security"} 0`**, from as many as 19 each: themis,
delphi, prometheus, grafana and moby were all 16-19 behind, lenora 2, and
pistis, loki, jellyfin, navidrome and hermes were already current.

Two invariants were proved against live hosts rather than argued:

- **moby's `docker-ce` stayed at `5:29.8.1-1~debian.13~trixie`** through an
  upgrade that replaced its `libssl3t64`, `openssl`, `nginx` and `curl`. All
  nine containers across the three stacks kept running and `.73`/`.74` stayed
  on `eth0`.
- **lenora's `proxmox-kernel-*` was untouched** — the two packages it took were
  `libbrotli1` and `libunbound8`. All eleven containers stayed up, `pveproxy`,
  `pvedaemon`, `pvestatd`, `zfs-zed` and `nfs-server` all active, three zpools
  ONLINE, no reboot required.

The DNS stack was deployed one host at a time rather than in one sweep, which
invariant 5 permits but does not require. Afterwards delphi still recursed and
still blocked the DoH names from its RPZ feeds, and themis answered on all
three transports — plain, DoT on `:853` serving the lab leaf plus the G3
intermediate, and DoH on `:443` returning the right answer to a wire-format
POST. `vpn-domain-sync`'s own metrics were intact.

`apt/scripts/verify.sh` then passed on all twelve, and `grafana/` was deployed
after the fleet, in that order, for the NoData reason above — 47 rules, the four
new ones provisioned.

### Forcing a run

`systemctl start apt-daily-upgrade.service` **may silently do nothing**: it runs
`/usr/lib/apt/apt.systemd.daily install`, which skips when the stamp is recent.
Observed on pythia, where a 14-minute-old stamp made it a no-op while a
10-minute-old stamp on prometheus did not — so this is an observation, not a
rule with a threshold anyone should rely on. To make something definitely
happen, run `unattended-upgrade -v` directly, and remember it moves the stamp.
