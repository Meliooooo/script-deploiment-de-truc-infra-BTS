#!/bin/bash
# Usage: curl -sL https://raw.githubusercontent.com/.../install-beats-linux.sh | bash
# Ou : bash install-beats-linux.sh [filebeat|auditbeat|metricbeat|all]

set -xe

BEAT="${1:-all}"
LOGSTASH_HOST="${LS_HOST:-192.168.1.104}"

# --- Ajout repo Elastic (1 ligne) ---
apt install gpg
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic-keyring.gpg 2>/dev/null && \
echo "deb [signed-by=/usr/share/keyrings/elastic-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" | tee /etc/apt/sources.list.d/elastic-9.x.list > /dev/null

# --- Installation ---
apt-get update -qq 2>/dev/null

case "$BEAT" in
  auditbeat) apt-get install -y -qq auditbeat ;;
  all)       apt-get install -y -qq auditbeat ;;
esac

# --- Configuration Logstash pour chaque beat installé ---
for b in filebeat auditbeat; do
  cfg="/etc/$b/$b.yml"
  [ -f "$cfg" ] && sed -i "s|output.elasticsearch:|#output.elasticsearch:|" "$cfg" && \
    echo -e "\noutput.logstash:\n  hosts: [\"$LOGSTASH_HOST:5044\"]" >> "$cfg" && \
    systemctl enable "$b" --now 2>/dev/null || true
done

echo "Beat(s) installed → envoyant vers $LOGSTASH_HOST:5044"
