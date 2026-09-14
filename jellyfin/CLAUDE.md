# Jellyfin

CT 300, **192.168.1.60**. UI on plain HTTP `:8096`; HTTPS on `:8920` exists
only for Prometheus.

## Working on this

`root/` mirrors the container filesystem and is the source of truth. **Never
edit `/etc/jellyfin/network.xml` on .60** – Jellyfin rewrites that file from
its own UI, so a change made there will be silently reverted by a deploy, and a
change made in the UI will be silently reverted too. Settings that matter go
here.

## Invariants

1. **8096 is deliberately plain HTTP, and `RequireHttps` is off.** Media
   streaming is LAN-only, so the UI is not encrypted and nothing redirects to
   8920. (`RequireHttps` never applied to LAN clients anyway – Jellyfin only
   enforces it for addresses it considers remote – but leaving it on invited
   someone to "fix" that.)

2. **8920 stays HTTPS so Prometheus can scrape `/metrics` over TLS.** Both
   ports are served side by side by the same process, so this costs nothing.
   `verify.sh` checks the chain on 8920 for that reason alone.

3. **Jellyfin needs a PKCS#12 bundle, not a PEM pair.** `/etc/homelab-tls/
   jellyfin.pfx` is built from `host.crt` and `host.key` by
   `post-renew.d/20-jellyfin`, which therefore must run at enrolment *and*
   after every renewal – otherwise Jellyfin keeps serving the old certificate
   until it expires. `deploy.sh` runs the hook explicitly before restarting,
   because Jellyfin fails to start if `CertificatePath` points at nothing.

4. **The G3 intermediate must be in the system trust store.** .NET loads the
   bundle with `X509Certificate2`, which takes only the *first* certificate –
   so Kestrel served a bare leaf and every client failed with "unable to verify
   the first certificate", even though the PFX contained the chain. With the
   intermediate in the store, .NET builds and sends the chain itself.
   `ca/scripts/enrol.sh` installs it everywhere. This was found the hard way.

5. **`CertificatePassword` is empty on purpose.** Jellyfin stores it in
   cleartext in `network.xml`, so a password protects the bundle from nobody
   while adding a second thing to keep in sync.
