#!/usr/bin/env bash
# Install the public n8n.peetvandesande.com vhost on ruby. From ruby's clone:
#   cd ~/homelab && git pull && sudo moby/scripts/install-ruby.sh
# Safe to re-run. The work is in shared/install-ruby-vhost.sh.
#
# Only webhooks, forms and their assets are public; the editor is limited to
# snippets/home-lan-allow.conf - see the vhost.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../shared/install-ruby-vhost.sh \
  "$PWD/ruby/etc/nginx/sites-available/n8n.peetvandesande.com" \
  n8n.peetvandesande.com moby.home
