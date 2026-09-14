# Grafana

CT 104, **192.168.1.54**. UI over TLS on `:3000`, reaching Prometheus over TLS.

## Working on this

`root/` mirrors the container filesystem and is the source of truth.
`scripts/deploy.sh` pushes it; `scripts/verify.sh` checks the UI, the chain and
the trust path to Prometheus.

Deploy **after** `prometheus/` — the datasource pushed here points at `https`,
so doing it first leaves every dashboard broken in between.

## Invariants

1. **TLS is configured with `GF_*` environment variables in a systemd drop-in,
   not by editing `/etc/grafana/grafana.ini`.** That file is ~2000 lines of
   packaged defaults, currently untouched; owning a copy here would mean
   re-merging it on every Grafana upgrade. `GF_SERVER_*` overrides the ini and
   is the documented mechanism.

2. **Grafana verifies Prometheus against the system trust store**, into which
   `ca/scripts/enrol.sh` installed the G2 root. `tlsSkipVerify` stays `false` —
   this is a real check, and setting it true would make the whole migration
   decorative.

3. **The datasource URL is an IP.** `.home` does not resolve anywhere on this
   LAN until the DHCP cutover to Themis; the certificate carries an IP SAN for
   this. Change it to a name only after the cutover.

## Verifying trust without credentials

`verify.sh` does not log into Grafana. It asks the equivalent question from
grafana's own container — does a plain `curl` with no `--cacert` reach
Prometheus over TLS? — because that is the same system trust store Grafana
uses. A pass there means the datasource can connect.

4. **Never add or change `uid:` on a provisioned datasource that already
   exists.** Grafana 13 looks the existing one up by that uid, fails with
   "data source not found", and refuses to start — the whole UI goes down,
   and `is-active` still flickers true because `Restart=on-failure` keeps
   relaunching it. `deploy.sh` therefore waits for a 200 from `/api/health`
   before reporting success. To pin a uid, delete the datasource in the UI
   first so provisioning creates it fresh.

## Datasources

Both are provisioned from `root/etc/grafana/provisioning/datasources/` and
read-only in the UI. "Add data source" there does not edit a provisioned one;
it creates an empty duplicate (`loki-1`) beside it. Edit the file and deploy.
`verify.sh` reads Grafana's own database to assert exactly one Loki datasource
exists at the https URL, so a straggler fails the check.

## Dashboards

Provisioned from files too: the provider is
`root/etc/grafana/provisioning/dashboards/homelab.yaml`, the JSON is one file
per dashboard under `root/var/lib/grafana/dashboards/`, and they land in the
"Homelab" folder, read-only in the UI. Edit the JSON and deploy; Grafana
re-reads the directory every 30 s, so a changed dashboard only needs the push
(a *new provider* needs the restart `deploy.sh` does anyway). To prototype in
the UI, "Save as" a copy, export its JSON model, paste it back over the file
and keep the `uid` - the uid is the URL (`/d/esxi`).

5. **Dashboards reference the Loki datasource through a hidden `${loki}`
   datasource variable, not by uid.** The provisioned datasource has no
   pinned uid (invariant 4 says why one must never be added to a live one),
   so a hard-coded uid would be a guess that breaks on the next reinstall.

6. **Grafana 13 stores dashboards in unified storage** - the `resource`
   table in `grafana.db`, one JSON document per object - and the legacy
   `dashboard` table stays empty. `verify.sh` reads the former. A JSON file
   the provider rejects is logged as a provisioning error and skipped, and
   the file being on disk proves nothing, so `verify.sh` lists each uid it
   expects to find.

| uid    | Title          | Source                            |
|--------|----------------|-----------------------------------|
| `esxi` | ESXi - esther  | Loki only: `esxi-smart` + syslog  |

