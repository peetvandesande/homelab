# Jellyfin

CT 300, **192.168.8.60**. Plain HTTP on `:8096`, UI and `/metrics` alike.

## Working on this

`root/` mirrors the container filesystem and is the source of truth. **Never
edit `/etc/jellyfin/network.xml` on jellyfin** – Jellyfin rewrites that file from
its own UI, so a change made there will be silently reverted by a deploy, and a
change made in the UI will be silently reverted too. Settings that matter go
here.

## Invariants

1. **8096 is deliberately plain HTTP, and there is no HTTPS listener.** Media
   streaming is LAN-only, so the UI is not encrypted. `EnableHttps` and
   `RequireHttps` are both off and `CertificatePath` is empty, so nothing
   listens on 8920. Prometheus scrapes `/metrics` on 8096 over plain HTTP too.
   If the scrape ever needs to be TLS, put an nginx in front for `/metrics`
   rather than turning HTTPS back on in Jellyfin – that meant a PKCS#12 bundle
   rebuilt on every renewal, and .NET serving a bare leaf unless the G3
   intermediate was in the system store.

2. **The host stays enrolled in the CA** because node-exporter on `:9100`
   still serves the lab certificate. Jellyfin itself no longer reads the key,
   so it is not in `tlscert` and has no `post-renew.d` hook; `deploy.sh`
   removes both, and the old `jellyfin.pfx`, from a host that still has them.

3. **`EnableIPv6` is on**, since the lab's IPv6 rollout. Kestrel then binds
   `::` as well as `0.0.0.0`, so `jellyfin.home` answers over either family,
   still plain HTTP. Jellyfin rewrites `network.xml` from its own UI, so this
   is one of the settings the warning at the top is about.
