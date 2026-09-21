# node-exporter

TLS for `prometheus-node-exporter` on `:9100`, across **all eleven enrolled
hosts** — the ten containers plus lenora.

One directory rather than eleven, because this is one service replicated, not
a per-container concern. It is the exception to the one-directory-per-container
shape the service stacks use.

## Working on this

`root/` mirrors the container filesystem and is the source of truth; the same
two files go to every host. `scripts/deploy.sh` pushes them,
`scripts/verify.sh` checks all eleven. `scripts/deploy.sh <ip>` does one host,
for bringing a new container in without bouncing the rest.

Hosts must be enrolled first (`ca/scripts/enrol.sh --all`) — deploy refuses
otherwise, because a target with TLS enabled and no certificate comes up broken
and surfaces as a scrape error somewhere else entirely.

## Invariants

1. **The systemd drop-in overrides `ExecStart`; it does not edit
   `/etc/default/prometheus-node-exporter`.** That file carries per-host
   collector flags — `$ARGS` differs between lenora and the containers — and
   this drop-in has to be byte-identical everywhere. Clearing `ExecStart=`
   before setting it is required; systemd appends otherwise and refuses to
   start a unit with two.

2. **Deploying this breaks every `node` scrape until `prometheus/` is
   deployed.** The exporters go TLS here; Prometheus learns to speak TLS there.
   Run them in that order, in the same sitting.

3. **`prometheus` is the exporter's user on every host, including lenora**, and
   must be in the `tlscert` group to read the key. `deploy.sh` does this.

## Gotcha

A TLS-only Go server answers plain HTTP with **400 "Client sent an HTTP request
to an HTTPS server"** — it does not refuse the connection. Any check that keys
off curl's exit status will call a correctly-configured exporter broken. Assert
"not 200", not "connection failed".
