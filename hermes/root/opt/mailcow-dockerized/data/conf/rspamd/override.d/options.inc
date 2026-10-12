# Managed from homelab/hermes. Replaces mailcow's local.d/options.inc, so its
# settings are repeated here; only local_addrs differs.
dns {
  enable_dnssec = true;
}
map_watch_interval = 30s;
task_timeout = 30s;
enable_mime_utf = true;
disable_monitoring = true;
soft_reject_on_timeout = true;
# The labs relay through postfix's mynetworks, and rspamd should treat them the
# same way: a local sender is not greylisted or RBL-checked, so a lab app's
# first message is not deferred with a 451 it may never retry.
local_addrs = ["/etc/rspamd/custom/mailcow_networks.map", "/etc/rspamd/override.d/homelab-local-addrs.map"];
