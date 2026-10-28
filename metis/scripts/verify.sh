#!/usr/bin/env bash
# Checks the intent of metis/: Ollama on the P2200, serving the job search
# models to moby and nobody else, monitored like every host. Read-only.
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ../ca/scripts/verify-lib.sh
HOST=192.168.8.58
LENORA=192.168.8.21
MOBY=192.168.8.27
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

echo "== VM"
$SSH "root@$LENORA" 'qm config 110 | grep -q "^onboot: 1"' 2>/dev/null \
  && pass "VM 110 starts at boot" || bad "VM 110 starts at boot" "onboot is not 1"
$SSH "root@$LENORA" 'qm config 110 | grep -q "^hostpci0: mapping=uc1-gpu"' 2>/dev/null \
  && pass "the P2200 is passed through" || bad "the P2200 is passed through" "no hostpci0 - create-vm.sh"
$SSH "root@$LENORA" 'qm agent 110 ping' 2>/dev/null \
  && pass "guest agent answers" || bad "guest agent answers" "qm agent 110 ping failed"

echo "== GPU and Ollama"
gpu=$($SSH "root@$HOST" 'nvidia-smi --query-gpu=name,driver_version --format=csv,noheader' 2>/dev/null)
[[ $gpu == *P2200* ]] && pass "nvidia-smi sees the card ($gpu)" || bad "nvidia-smi sees the card" "${gpu:-no output} - driver loaded?"
$SSH "root@$HOST" 'systemctl is-active --quiet ollama' 2>/dev/null \
  && pass "ollama is active" || bad "ollama is active" "journalctl -u ollama"
for m in bge-m3 qwen3:4b; do
  $SSH "root@$HOST" "ollama list | grep -q '^$m'" 2>/dev/null \
    && pass "model $m is pulled" || bad "model $m is pulled" "bootstrap.sh"
done
# The real path: from inside moby's n8n-sogode container, by name.
dims=$($SSH "root@$MOBY" "docker exec n8n-sogode-n8n-1 wget -qO- --post-data='{\"model\":\"bge-m3\",\"input\":\"sovereign cloud\"}' http://ollama.home:11434/api/embed" 2>/dev/null \
       | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["embeddings"][0]))' 2>/dev/null)
[[ $dims == 1024 ]] && pass "n8n-sogode gets 1024-dim bge-m3 embeddings" || bad "n8n-sogode gets bge-m3 embeddings" "got '${dims}'"
proc=$($SSH "root@$HOST" 'ollama ps' 2>/dev/null | awk '/bge-m3/ {print $0}')
[[ $proc == *GPU* ]] && pass "bge-m3 runs on the GPU" || warn "bge-m3 runs on the GPU" "${proc:-not loaded right now}"

echo "== exposure"
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$HOST:11434/api/tags" 2>/dev/null)
[[ $code == 000 ]] && pass "Ollama refuses this workstation" || bad "Ollama refuses this workstation" "http=$code - nftables?"

echo "== monitoring"
https_ok "$HOST:9100" "https://$HOST:9100/metrics"
https_ok "$HOST:12345" "https://$HOST:12345/-/ready"
echo
[[ $fail -eq 0 ]] && echo "all checks passed" || { echo "$fail check(s) failed"; exit 1; }
