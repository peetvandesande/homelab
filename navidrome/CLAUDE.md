# Navidrome

CT 301, **192.168.1.61**. Plain HTTP on `:4533`, UI and `/metrics` alike.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/deploy.sh` pushes it; `scripts/verify.sh` checks the result.

## Invariants

1. **4533 is deliberately plain HTTP.** Media streaming is LAN-only, so the UI
   is not encrypted. Navidrome has a single listener, so `TLSCert`/`TLSKey`
   would switch the UI and `/metrics` to HTTPS together – and any client still
   pointed at `http://192.168.1.61:4533` would stop working rather than being
   redirected. Prometheus therefore scrapes this port over plain HTTP too. If
   the scrape ever needs to be TLS, put an nginx in front for `/metrics`
   rather than turning TLS on in Navidrome.

2. **The host stays enrolled in the CA** because node-exporter on `:9100`
   still serves the lab certificate. Navidrome itself no longer reads the key,
   so it is not in `tlscert` and has no `post-renew.d` hook.

3. **This container's rootfs is on `local-zfs`, not `ssdpool`.** Pre-existing
   anomaly – noted here only so nobody "fixes" it during a rebuild without
   asking.
