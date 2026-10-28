#!/usr/bin/env bash
# Install the public ntfy.sogode.com vhost on ruby. From ruby's clone, once
# ntfy.sogode.com is a CNAME to ruby:
#   cd ~/homelab && git pull && sudo moby/scripts/install-ruby-ntfy.sh
# Safe to re-run. The work is in shared/install-ruby-vhost.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec ../shared/install-ruby-vhost.sh \
  "$PWD/ruby/etc/nginx/sites-available/ntfy.sogode.com" \
  ntfy.sogode.com moby.home
