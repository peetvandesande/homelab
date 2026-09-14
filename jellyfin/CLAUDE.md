# Jellyfin

CT 300, **192.168.1.60**. HTTPS on `:8920`; `:8096` stays bound.

## Working on this

`root/` mirrors the container filesystem and is the source of truth. **Never
edit `/etc/jellyfin/network.xml` on .60** — Jellyfin rewrites that file from
its own UI, so a change made there will be silently reverted by a deploy, and a
change made in the UI will be silently reverted too. Settings that matter go
here.

## Invariants

1. **Jellyfin needs a PKCS#12 bundle, not a PEM pair.** `/etc/homelab-tls/
   jellyfin.pfx` is built from `host.crt` and `host.key` by
   `post-renew.d/20-jellyfin`, which therefore must run at enrolment *and*
   after every renewal — otherwise Jellyfin keeps serving the old certificate
   until it expires. `deploy.sh` runs the hook explicitly before restarting,
   because Jellyfin fails to start if `CertificatePath` points at nothing.

2. **The G3 intermediate must be in the system trust store.** .NET loads the
   bundle with `X509Certificate2`, which takes only the *first* certificate —
   so Kestrel served a bare leaf and every client failed with "unable to verify
   the first certificate", even though the PFX contained the chain. With the
   intermediate in the store, .NET builds and sends the chain itself.
   `ca/scripts/enrol.sh` installs it everywhere. This was found the hard way.

3. **`CertificatePassword` is empty on purpose.** Jellyfin stores it in
   cleartext in `network.xml`, so a password protects the bundle from nobody
   while adding a second thing to keep in sync.

4. **Prometheus scrapes 8920, not 8096.** See below for why chasing the
   redirect is not an option.

## RequireHttps does not do what it sounds like

`RequireHttps` is set, and **8096 still does not redirect LAN clients to
HTTPS**. Jellyfin applies it only to requests it considers *remote*; with
`LocalNetworkSubnets` empty it auto-detects 192.168.1.0/24 as local, so every
client in this lab is exempt. `verify.sh` reports this as WARN rather than
pretending otherwise.

Jellyfin cannot be made to drop 8096. If plain HTTP genuinely has to go, the
options are a firewall rule on 8096, or setting `LocalNetworkSubnets` to
something that excludes the LAN — the latter also changes remote-access
handling and streaming limits, so it is not a free switch.
