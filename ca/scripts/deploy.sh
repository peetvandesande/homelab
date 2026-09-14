#!/usr/bin/env bash
# Push configuration and CA material to pistis and bring step-ca up.
# Run from anywhere; operates on the repo it lives in. Idempotent.
#
# Files are copied one at a time and written atomically as root:root - same
# reasoning as homelab/dns/scripts/deploy.sh, which learned the hard way that
# streaming a tarball into / rewrites / to the workstation's uid and mode.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f secrets.env ]] || { echo "secrets.env missing - see README.md"; exit 1; }
# shellcheck disable=SC1091
source secrets.env
: "${STEP_CA_KEY_PASSWORD:?not set in secrets.env}"
: "${STEP_CA_JWK_PASSWORD:?not set in secrets.env}"

PISTIS=192.168.1.55
INT="intermediate"
CRT="$INT/certs/intermediate-g3.crt"
KEY="$INT/private/intermediate-g3.key"

[[ -f "$CRT" && -f "$KEY" ]] || {
  echo "intermediate CA not built yet - run scripts/make-intermediate.sh first"; exit 1; }

# %C is a short hash; macOS temp dirs blow past the 104-char sockaddr limit.
CTL="/tmp/.cadeploy-%C"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=60s"

# Lowercase hex SHA-256 of the DER - the same string `step certificate
# fingerprint` prints, and what clients pass to `step ca bootstrap`.
ROOT_FINGERPRINT=$(openssl x509 -in rootca/certs/root.crt -outform DER \
  | openssl dgst -sha256 | awk '{print $NF}')

esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

subst() {
  sed -e "s|@@ROOT_FINGERPRINT@@|$(esc "$ROOT_FINGERPRINT")|g" \
      -e "s|@@JWK_PROVISIONER@@|$(esc "${JWK_PROVISIONER:-}")|g" "$1"
}

push() { # push <srcdir>
  local src=$1 rel mode
  echo "== pushing $src -> $PISTIS"
  while IFS= read -r rel; do
    rel=${rel#./}
    mode=0644
    [[ -x "$src/$rel" ]] && mode=0755
    subst "$src/$rel" | $SSH "root@$PISTIS" \
      "mkdir -p '/$(dirname "$rel")' && cat > '/$rel.deploytmp' \
       && chown root:root '/$rel.deploytmp' && chmod $mode '/$rel.deploytmp' \
       && mv -f '/$rel.deploytmp' '/$rel'"
    echo "   $rel ($mode)"
  done < <(cd "$src" && find . -type f ! -name .gitkeep | sort)
}

put() { # put <localfile> <remotepath> <owner> <mode>
  $SSH "root@$PISTIS" \
    "cat > '$2.deploytmp' && chown '$3' '$2.deploytmp' && chmod '$4' '$2.deploytmp' \
     && mv -f '$2.deploytmp' '$2'" < "$1"
  echo "   $2 ($3 $4)"
}

# ------------------------------------------------------- CA material -------
# Certs and keys before config: `step ca provisioner add` below loads the
# authority, which reads these paths, and step-ca itself will not start
# without them.
echo "== installing CA material"
$SSH "root@$PISTIS" '
  id -u step >/dev/null 2>&1 || useradd --system --home /var/lib/step-ca --shell /usr/sbin/nologin step
  install -d -o step -g step -m 0700 /var/lib/step-ca /etc/step-ca/secrets
  install -d -o step -g step -m 0755 /etc/step-ca /etc/step-ca/config /etc/step-ca/certs
  install -d -o root -g root -m 0755 /var/www /var/www/g3
'
put rootca/certs/root.crt /etc/step-ca/certs/root_ca.crt         step:step 0644
put "$CRT"                /etc/step-ca/certs/intermediate_ca.crt step:step 0644
put "$KEY"                /etc/step-ca/secrets/intermediate_ca_key step:step 0600

# The key stays encrypted on disk; this is what decrypts it at startup. 0400
# and step-owned, in a 0700 directory.
printf '%s' "$STEP_CA_KEY_PASSWORD" | $SSH "root@$PISTIS" \
  "cat > /etc/step-ca/secrets/password.deploytmp \
   && chown step:step /etc/step-ca/secrets/password.deploytmp \
   && chmod 0400 /etc/step-ca/secrets/password.deploytmp \
   && mv -f /etc/step-ca/secrets/password.deploytmp /etc/step-ca/secrets/password"
echo "   /etc/step-ca/secrets/password (step:step 0400)"

# The JWK provisioner password, so admin issuance on pistis itself needs no
# typing - and so verify.sh can prove issuance end to end unattended.
printf '%s' "$STEP_CA_JWK_PASSWORD" | $SSH "root@$PISTIS" \
  "cat > /etc/step-ca/secrets/jwk-password.deploytmp \
   && chown step:step /etc/step-ca/secrets/jwk-password.deploytmp \
   && chmod 0400 /etc/step-ca/secrets/jwk-password.deploytmp \
   && mv -f /etc/step-ca/secrets/jwk-password.deploytmp /etc/step-ca/secrets/jwk-password"
echo "   /etc/step-ca/secrets/jwk-password (step:step 0400)"

# A CRL that expired years ago fails closed in anything that actually checks
# it, and it is silent until the day it bites. Check before publishing, not
# after - and locally, because `openssl crl` has no -checkend and BSD and GNU
# date disagree on parsing its nextUpdate.
crl_fresh() { # crl_fresh <file>
  python3 - "$1" <<'CRLPY'
import subprocess, sys, datetime
out = subprocess.run(["openssl", "crl", "-in", sys.argv[1], "-noout", "-nextupdate"],
                     capture_output=True, text=True, check=True).stdout
when = datetime.datetime.strptime(out.split("=", 1)[1].strip(),
                                  "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
sys.exit(0 if when > datetime.datetime.now(datetime.timezone.utc) else 1)
CRLPY
}
crl_fresh rootca/crl/root.crl || {
  echo "rootca/crl/root.crl has expired - run scripts/root-crl.sh, then re-run this"; exit 1; }

# ------------------------------------------- published files (nginx) -------
# These paths are baked into every certificate the G2 root signs - the G3
# cert's crlDistributionPoints and authorityInfoAccess name them literally.
echo "== publishing /var/www/g3"
put rootca/certs/root.crt      /var/www/g3/root.crt        root:root 0644
put rootca/crl/root.crl        /var/www/g3/root.crl        root:root 0644
put "$CRT"                     /var/www/g3/intermediate.crt root:root 0644
put "$INT/certs/chain-g3.pem"  /var/www/g3/chain.pem       root:root 0644

# --------------------------------------------- JWK provisioner (once) ------
# Minted on the host and stored in secrets.env, never regenerated: the kid is
# baked into any client that has bootstrapped against it, and `--create` mints
# a fresh one every time it is called.
if [[ -z "${JWK_PROVISIONER:-}" ]]; then
  echo "== minting JWK admin provisioner"
  # Assembled by hand rather than with `step ca provisioner add`: that command
  # requires --ca-url and talks to the admin API of a *running* CA, which is
  # exactly what we do not have yet (and with enableAdmin false, never will).
  #
  # `step crypto jwk create` writes the encrypted private key as JWE **JSON**
  # serialization; the provisioner's encryptedKey field wants **compact**
  # serialization, hence the join on ".".
  JWK_PROVISIONER=$($SSH "root@$PISTIS" "
      set -e
      umask 077
      d=\$(mktemp -d); trap 'rm -rf \$d' EXIT; cd \$d
      printf '%s' '$STEP_CA_JWK_PASSWORD' > pw
      step crypto jwk create pub.json priv.json --password-file pw \
        --use sig --kty EC --crv P-256 --alg ES256 >/dev/null 2>&1
      jq -c --slurpfile pub pub.json \
        '{type:\"JWK\", name:\"admin\", key:\$pub[0],
          encryptedKey:([.protected,.encrypted_key,.iv,.ciphertext,.tag]|join(\".\"))}' priv.json
    ")
  [[ $JWK_PROVISIONER == *'"encryptedKey"'* ]] || { echo "provisioner mint failed: $JWK_PROVISIONER"; exit 1; }
  printf "JWK_PROVISIONER='%s'\n" "$JWK_PROVISIONER" >> secrets.env
  echo "   stored in secrets.env"
fi

# ------------------------------------------------------------- config ------
push pistis

$SSH "root@$PISTIS" '
  set -e
  chown step:step /etc/step-ca/config/ca.json /etc/step-ca/config/defaults.json
  chmod 0640 /etc/step-ca/config/ca.json
  chmod 0644 /etc/step-ca/config/defaults.json

  # Our site is a default_server; so is the packaged one. Two of them is a
  # fatal config error, not a warning.
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/g3.conf /etc/nginx/sites-enabled/g3.conf
  nginx -t
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx

  systemctl daemon-reload
  systemctl reset-failed step-ca 2>/dev/null || true
  systemctl enable --now step-ca >/dev/null
'

# Restart, then assert it settled. A bare restart can report failure while the
# outgoing process still holds its listener; what matters is the end state.
$SSH "root@$PISTIS" "
  systemctl restart step-ca || true
  for _ in \$(seq 1 30); do systemctl is-active --quiet step-ca && exit 0; sleep 1; done
  echo 'step-ca did not come up'; journalctl -u step-ca --no-pager -n 30; exit 1
"

echo
echo "== deployed"
echo "   root fingerprint: $ROOT_FINGERPRINT"
echo "   now run scripts/verify.sh"
