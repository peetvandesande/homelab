# homeassistant

TLS for the Home Assistant VM (302, **192.168.8.90**) off the lab CA, and the
renewal that keeps it alive. Home Assistant itself is configured in its own
GUI and `configuration.yaml`; this directory owns only the certificate.

```
scripts/issue.sh    first issue, and recovery after an expiry
scripts/deploy.sh   install the renewal driver + timer on lenora
scripts/verify.sh   smoke test TLS and the renewal path
haos/ha-tls.py      runs inside the core container - CSR, renew, info
lenora/             the driver and its systemd timer
```

## Why the renewal lives on lenora

Every other host renews itself: `ca/fleet/usr/local/bin/homelab-tls-renew` on a
daily timer. HAOS cannot do that, for three reasons that each rule out the
obvious approach:

1. **No tooling.** There is no `step-cli` and no `openssl` anywhere on the
   appliance - not on the host, not in the core container. `cryptography` and
   `requests` ship with Home Assistant, which is why `haos/ha-tls.py` runs
   inside the core container rather than beside it.
2. **`/ssl` is read-only to the core container.** Home Assistant reads its
   certificate from `/ssl` and cannot write there. So the helper stages a new
   bundle in `/config`, which is writable, and the driver moves it across from
   the HAOS host side. This is the single most surprising fact here, and it is
   what stops the whole thing being a Home Assistant automation.
3. **A renewal inside Home Assistant cannot recover Home Assistant.** If the
   certificate lapses and HA will not serve, an HA automation never fires - and
   renewal needs an HA restart to take effect, so it would be asking HA to
   restart itself immediately after rewriting its own TLS config. The driver on
   lenora has no dependency on HA being healthy.

Access is the **qemu guest agent** (`qm guest exec 302`), not SSH: HAOS has no
SSH without an add-on, and the agent works even when HA's own network config is
broken - which is how the LAN NIC was recovered in October 2026.

## Invariants

1. **The private key is generated inside HAOS and never leaves it.** `issue.sh`
   has the core container generate the key and emit only a CSR; signing happens
   on pistis. Renewal is mTLS - the existing certificate authenticates the
   request - so nothing here holds a provisioner password. Same rule as
   `ca/scripts/enrol.sh`, reached a different way because HAOS cannot redeem a
   token itself.

2. **`step ca sign` already returns leaf+intermediate.** Do not append the
   intermediate again: you get a duplicate, which works but is wrong. The
   renew endpoint's `certChain` is the same two-certificate bundle, in order.

3. **The certificate and the supervisor must agree.** Home Assistant serving
   `:80` while `ha core options` says `ssl: true, port: 443` is what makes HA
   look broken, and it is the state to suspect first. `verify.sh` checks both.
   `ha core check` does **not** catch it - it validates YAML, not reachability.

4. **A quoted leading space in `ssl_certificate` fails as "not a file".** Plain
   YAML strips spaces after a colon, so `ssl_certificate: " /ssl/..."` is the
   only way to get one, and the error quotes the value back with the space in
   it. Worth knowing because the message reads like a missing file.

5. **An expired certificate cannot renew.** step-ca has
   `allowRenewalAfterExpiry` false, so renewal past `notAfter` is refused. The
   helper says so rather than failing on a 401. Recovery is `issue.sh`, which
   mints a fresh token - the same shape as re-running `enrol.sh` for a host
   that drifted past expiry.

6. **A `net` change applies to the VM config, not to the running VM.** Adding a
   NIC needs `echo 1 > /sys/bus/pci/rescan` in the guest or a power cycle;
   removing one leaves the device attached until the VM restarts. The guest also
   keeps the NetworkManager profile after a NIC goes, which is what lets a
   restored NIC come straight back up.

## Renewal

Daily timer on lenora, jitter and `Persistent=true`, same shape as the fleet's.
Certificates are 30 days and renew under **10 days** remaining, so there are
nine chances to ride out a CA outage.

```sh
systemctl list-timers homelab-ha-tls-renew.timer   # on lenora
/usr/local/bin/homelab-ha-tls-renew --force        # renew now
/usr/local/bin/homelab-ha-tls-renew --no-restart   # stage without restarting HA
```

The driver **restarts Home Assistant by default**, because until it does the
renewal has achieved nothing - HA reads the certificate once, at startup. The
previous bundle is kept at `/ssl/homeassistant.crt.prev`, and the driver waits
for a verified handshake on `:443` before reporting success.

## Home Assistant's own side

Not managed here, deliberately - it is GUI and `configuration.yaml` territory:

```yaml
http:
  ssl_certificate: /ssl/homeassistant.crt
  ssl_key: /ssl/homeassistant.key
```

plus `ha core options --ssl=true --port 443` so the supervisor agrees. Note
there is **no GUI for core SSL** - the `http` integration is YAML-only. The
GUI-configurable route is a proxy add-on in front of core, which reads the same
files out of `/ssl`.

`/ssl` also holds `root_ca.crt`, put there by `issue.sh` so renewal can verify
the CA rather than trusting it blindly.
