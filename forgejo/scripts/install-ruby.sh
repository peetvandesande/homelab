#!/usr/bin/env bash
# Install the public git.peetvandesande.com vhost on ruby. From ruby's clone:
#   cd ~/homelab && git pull && sudo forgejo/scripts/install-ruby.sh
# Safe to re-run. The work is in shared/install-ruby-vhost.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../shared/install-ruby-vhost.sh \
  "$PWD/ruby/etc/nginx/sites-available/git.peetvandesande.com" \
  git.peetvandesande.com forgejo.home
