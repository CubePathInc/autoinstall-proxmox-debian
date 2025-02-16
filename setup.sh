#!/usr/bin/env bash
set -euo pipefail

# 1) Prepare /etc/postfix/main.cf to avoid numeric-hostname breakage
mkdir -p /etc/postfix
if [[ ! -f /etc/postfix/main.cf ]]; then
  echo "# Placeholder for Postfix config" > /etc/postfix/main.cf
fi
sed -i -E 's/^[[:space:]]*myhostname[[:space:]]*=.*/#myhostname = forced/' /etc/postfix/main.cf || true

# 2) Remove enterprise repo if it exists
rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true

# 3) Detect Debian version (bullseye / bookworm)
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "$ID" != "debian" ]]; then
    echo "Not Debian. Aborting."
    exit 1
  fi
  case "$VERSION_CODENAME" in
    bullseye|bookworm) PMX_CODENAME="$VERSION_CODENAME" ;;
    *) echo "Unsupported: $VERSION_CODENAME"; exit 1 ;;
  esac
else
  echo "Missing /etc/os-release. Aborting."
  exit 1
fi

# 4) Update & upgrade
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

# 5) Install Postfix + extras (if fails due to numeric hostname, ignore once)
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix open-iscsi chrony ifupdown2 || true

# 6) Re-comment myhostname, reload Postfix, fix broken packages
sed -i -E 's/^[[:space:]]*myhostname[[:space:]]*=.*/#myhostname = forced/' /etc/postfix/main.cf || true
systemctl reload postfix || true
DEBIAN_FRONTEND=noninteractive apt-get -f install -y

# 7) Add no-subscription Proxmox repo and install Proxmox VE
cat <<EOF >/etc/apt/sources.list.d/pve-install-repo.list
deb [arch=amd64] http://download.proxmox.com/debian/pve $PMX_CODENAME pve-no-subscription
EOF
wget -q "https://enterprise.proxmox.com/debian/proxmox-release-${PMX_CODENAME}.gpg" \
     -O "/etc/apt/trusted.gpg.d/proxmox-release-${PMX_CODENAME}.gpg" || true
chmod +r "/etc/apt/trusted.gpg.d/proxmox-release-${PMX_CODENAME}.gpg" || true

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-ve

# 8) Remove os-prober (optional)
DEBIAN_FRONTEND=noninteractive apt-get remove -y os-prober || true

# 9) Configure Proxmox bridge
backup_file="/etc/network/interfaces.bak.$(date +%s)"
cp /etc/network/interfaces "$backup_file"

main_if=""
main_address=""
main_netmask=""
main_gateway=""
dns_nameservers=""
dns_search=""
declare -A alias_map=()

trim() {
  local val="$*"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  echo -n "$val"
}

current_iface=""
while IFS= read -r line; do
  line="${line//,}"
  if [[ "$line" =~ ^iface[[:space:]]+([[:alnum:][:punct:]]+)[[:space:]]+inet[[:space:]]+static ]]; then
    current_iface="${BASH_REMATCH[1]}"
    [[ -z "$main_if" ]] && main_if="$current_iface"
  elif [[ -n "$current_iface" ]]; then
    if [[ "$line" =~ [[:space:]]*address[[:space:]]+(.+) ]]; then
      addr=$(trim "${BASH_REMATCH[1]}")
      if [[ "$current_iface" == "$main_if" && -z "$main_address" ]]; then
        main_address="$addr"
      else
        alias_map["$current_iface:$(echo "$addr" | cut -d'/' -f1)"]="$addr"
      fi
    elif [[ "$line" =~ [[:space:]]*netmask[[:space:]]+(.+) ]]; then
      [[ "$current_iface" == "$main_if" && -z "$main_netmask" ]] && main_netmask=$(trim "${BASH_REMATCH[1]}")
    elif [[ "$line" =~ [[:space:]]*gateway[[:space:]]+(.+) ]]; then
      [[ "$current_iface" == "$main_if" && -z "$main_gateway" ]] && main_gateway=$(trim "${BASH_REMATCH[1]}")
    elif [[ "$line" =~ [[:space:]]*dns-nameservers[[:space:]]+(.+) ]]; then
      dns_nameservers=$(trim "${BASH_REMATCH[1]}")
    elif [[ "$line" =~ [[:space:]]*dns-search[[:space:]]+(.+) ]]; then
      dns_search=$(trim "${BASH_REMATCH[1]}")
    fi
  fi
done < /etc/network/interfaces

if [[ -z "$main_if" || -z "$main_address" ]]; then
  echo "No primary static interface found. Aborting."
  exit 1
fi

if [[ "$main_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/([0-9]+)$ ]]; then
  :
else
  if [[ -n "$main_netmask" ]]; then
    IFS='.' read -r i1 i2 i3 i4 <<<"$main_netmask"
    bin=$(printf "%08d%08d%08d%08d" "$(bc <<<"obase=2;$i1")" "$(bc <<<"obase=2;$i2")" "$(bc <<<"obase=2;$i3")" "$(bc <<<"obase=2;$i4")")
    prefix_length=$(grep -o "1" <<<"$bin" | wc -l)
    main_address="${main_address}/${prefix_length}"
  fi
fi

cat <<EOF >/etc/network/interfaces
auto lo
iface lo inet loopback

auto $main_if
iface $main_if inet manual

auto vmbr0
iface vmbr0 inet static
    address $main_address
$( [[ -n "$main_gateway" ]] && echo "    gateway $main_gateway" )
    bridge-ports $main_if
    bridge-stp off
    bridge-fd 0
$( [[ -n "$dns_nameservers" ]] && echo "    dns-nameservers $dns_nameservers" )
$( [[ -n "$dns_search" ]] && echo "    dns-search $dns_search" )

EOF

if [[ ${#alias_map[@]} -gt 0 ]]; then
  echo "" >> /etc/network/interfaces
  for alias_if in "${!alias_map[@]}"; do
    alias_addr="${alias_map[$alias_if]}"
    if [[ "$alias_addr" =~ / ]]; then
      echo "iface $alias_if inet static" >> /etc/network/interfaces
      echo "    address $alias_addr" >> /etc/network/interfaces
      echo "" >> /etc/network/interfaces
    else
      if [[ -n "$main_netmask" ]]; then
        echo "iface $alias_if inet static" >> /etc/network/interfaces
        echo "    address $alias_addr" >> /etc/network/interfaces
        echo "    netmask $main_netmask" >> /etc/network/interfaces
        echo "" >> /etc/network/interfaces
      else
        echo "# WARNING: No netmask for $alias_if ($alias_addr)" >> /etc/network/interfaces
        echo "" >> /etc/network/interfaces
      fi
    fi
  done
fi

# 11) Enable IPv4 & IPv6 forwarding using /usr/sbin/sysctl
cat <<EOF >/etc/sysctl.d/99-proxmox-ipforward.conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
/usr/sbin/sysctl --system || true

echo "Done. Rebooting in 5 seconds..."
sleep 5
/usr/sbin/reboot
