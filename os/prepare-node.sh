#!/usr/bin/env bash
#
# Prepare a Raspberry Pi 5 (Raspberry Pi OS Lite 64-bit, Bookworm or newer)
# as a RICK node. Run once per node with sudo, while it has internet:
#
#   sudo ./os/prepare-node.sh <rick1|rick2|rick3|rick4> <node address> [router address]
#   sudo ./os/prepare-node.sh rick1 192.168.50.11 192.168.50.1
#
# It sets the hostname, gives the wired interface a fixed address, installs
# Docker Engine + Compose, and configures time keeping (chrony): rick1 serves
# time to the other nodes so the kit agrees on the clock when there is no
# internet. TLS certificates and logins depend on a correct clock: fit the
# Raspberry Pi RTC battery to rick1 at least.
#
# Options (environment):
#   RICK_PCIE_GEN3=1     enable PCIe Gen 3 for the NVMe SSD (faster, officially
#                        not certified; leave off if the SSD is unstable)
#   RICK_STATIC_IP=0     skip the fixed address (use a DHCP reservation instead)
#   RICK_DOCKER_USER     user added to the docker group (default: $SUDO_USER)

set -euo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "Run with sudo."
NAME="${1:-}"; ADDR="${2:-}"; ROUTER="${3:-}"
case "$NAME" in rick1|rick2|rick3|rick4) ;; *) die "Usage: sudo $0 <rick1|rick2|rick3|rick4> <node address> [router address]" ;; esac
[[ "$ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Give the node address, e.g. 192.168.50.11"
ROUTER="${ROUTER:-${ADDR%.*}.1}"
EDGE_ADDR="${RICK_EDGE_HOST:-${ADDR%.*}.11}"
[ "$(uname -m)" = aarch64 ] || echo "Warning: this is not a 64-bit ARM system ($(uname -m)); continuing."

info "Hostname: $NAME"
hostnamectl set-hostname "$NAME"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NAME/" /etc/hosts
grep -q "^127.0.1.1" /etc/hosts || printf '127.0.1.1\t%s\n' "$NAME" >> /etc/hosts

if [ "${RICK_STATIC_IP:-1}" = 1 ] && command -v nmcli >/dev/null 2>&1; then
  con="$(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-3-ethernet"{print $1; exit}')"
  if [ -n "$con" ]; then
    info "Fixed address $ADDR/24 on '$con' (gateway/DNS $ROUTER)"
    nmcli con mod "$con" ipv4.method manual ipv4.addresses "$ADDR/24" ipv4.gateway "$ROUTER" ipv4.dns "$ROUTER"
    echo "    The address applies after a reboot (or: sudo nmcli con up \"$con\")."
  else
    echo "Warning: no wired NetworkManager connection found; set the address manually or with a DHCP reservation."
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker Engine (get.docker.com)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
systemctl enable --now docker
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin missing after install."
user="${RICK_DOCKER_USER:-${SUDO_USER:-}}"
[ -n "$user" ] && usermod -aG docker "$user" && info "Added $user to the docker group (log out and back in)."

info "Installing tools (chrony, rsync, curl, openssl)"
apt-get update -qq
apt-get install -y -qq chrony rsync curl openssl >/dev/null

info "Time keeping (chrony)"
conf=/etc/chrony/conf.d/rick.conf
mkdir -p /etc/chrony/conf.d
if [ "$NAME" = rick1 ]; then
  cat > "$conf" <<EOF
# rick1 keeps time for the kit: internet NTP when online, otherwise its own
# clock (RTC battery) at a low stratum so the other nodes still follow it.
local stratum 8
allow ${ADDR%.*}.0/24
EOF
else
  cat > "$conf" <<EOF
# Follow rick1 so every node agrees on the time, with or without internet.
server $EDGE_ADDR iburst prefer
EOF
fi
grep -q "^confdir /etc/chrony/conf.d" /etc/chrony/chrony.conf || echo "confdir /etc/chrony/conf.d" >> /etc/chrony/chrony.conf
systemctl restart chrony

if [ "${RICK_PCIE_GEN3:-0}" = 1 ]; then
  cfg=/boot/firmware/config.txt
  if [ -f "$cfg" ] && ! grep -q "^dtparam=pciex1_gen=3" "$cfg"; then
    info "Enabling PCIe Gen 3 for the NVMe SSD ($cfg)"
    printf '\n# RICK: NVMe at PCIe Gen 3\ndtparam=pciex1_gen=3\n' >> "$cfg"
  fi
fi

# Redis recommends this; avoids failed background saves under memory pressure.
echo "vm.overcommit_memory = 1" > /etc/sysctl.d/90-rick.conf
sysctl -q -p /etc/sysctl.d/90-rick.conf

cat <<EOF

$NAME prepared. Reboot now (sudo reboot) so the address and settings apply.
Then copy the configured kit checkout to this node (./rick.sh sync from rick1)
and start it with ./rick.sh start.
EOF
