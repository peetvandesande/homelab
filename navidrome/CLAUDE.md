# Navidrome

CT 301, **192.168.1.61**. HTTPS on `:4533`.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/deploy.sh` pushes it; `scripts/verify.sh` checks the chain.

## Invariants

1. **`TLSCert`/`TLSKey` swap 4533 from HTTP to HTTPS in place.** There is no
   second port and no redirect, so any client still pointed at
   `http://192.168.1.61:4533` **stops working** rather than being redirected.
   That is the trade for a single port, and it is the one user-visible
   breakage in this migration.

2. **Navidrome reads the certificate at startup**, so `post-renew.d/
   20-navidrome` restarts it. A reload would not pick up a renewed cert.

3. **This container's rootfs is on `local-zfs`, not `ssdpool`.** Pre-existing
   anomaly, unrelated to TLS — noted here only so nobody "fixes" it during a
   rebuild without asking.
