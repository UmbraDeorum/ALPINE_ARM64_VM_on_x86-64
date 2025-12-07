#!/bin/bash

sudo ip link set tap0 down 1>&2 2>/dev/null
sudo ip link delete tap0 1>&2 2>/dev/null
sudo ip link set br0 down 1>&2 2>/dev/null
sudo ip link delete br0 type bridge 1>&2 2>/dev/null

set -euo pipefail

VM_NAME="alpine-arm64-vm"
VM_QCOW2="${VM_NAME}.qcow2"
ALPINE_VERSION="3.23.0"
VM_ISO="alpine-virt-${ALPINE_VERSION}-aarch64.iso"
VM_IP="172.20.0.10"
NETMASK="24"
NETWORK="172.20.0.0/24"
BRIDGE="br0"
TAP="tap0"
GATEWAY="172.20.0.1"
DNS_SERVER="8.8.8.8"
INTERNET_IF=$(ip route | grep default | awk '{print $5}' | head -n1)
MEM="8192"
CPU="max"
CORES="4"
ISO_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-virt-${ALPINE_VERSION}-aarch64.iso"
ANSWERS_FILE="alpine-answers-$$"

# Port forwarding
GDB_PORT=1234
FORWARD_PORTS=()

FILES_CREATED=()
INTERFACES_CREATED=()
IPTABLES_RULES=()
PROCESSES_CREATED=()

show_help() {
    cat << EOF
QEMU Alpine ARM64 VM Setup Script

USAGE:
    sudo $0 [OPTIONS]

OPTIONS:
    -h, --help       Show this help message
    -k, --keep-disk  Keep VM disk after cleanup (use for installed systems)
    -s, --ssh        Enable SSH port forwarding (host:2222 -> VM:22)
    -p, --port PORT  Forward additional port (can be used multiple times)
    -c, --cleanup    Cleanup network resources and exit

NETWORK CONFIGURATION:
    VM IP:      $VM_IP/$NETMASK
    Gateway:    $GATEWAY
    Bridge:     $BRIDGE
    TAP:        $TAP
    Network:    $NETWORK
    DNS:        $DNS_SERVER

PORT FORWARDING:
    GDB Port:   localhost:$GDB_PORT -> VM:$GDB_PORT (always enabled)
    SSH Port:   localhost:2222 -> VM:22 (with -s flag)
    Custom:     Use -p flag for additional ports

EXAMPLES:
    # First run (installation)
    sudo $0

    # After installation (keep disk)
    sudo $0 -k

    # With SSH access
    sudo $0 -k -s

    # With custom port forwarding
    sudo $0 -k -p 8080 -p 3000

    # GDB debugging
    sudo $0 -k
    # In VM: gdbserver :1234 ./program
    # On host: gdb-multiarch
    #          (gdb) target remote localhost:1234

    # Cleanup only
    sudo $0 -c

REQUIREMENTS:
    - Root privileges (sudo)
    - qemu-system-aarch64
    - qemu-efi-aarch64 or AAVMF
    - Bridge utilities
    - iptables

EOF
    exit 0
}

track_file() { FILES_CREATED+=("$1"); }
track_interface() { INTERFACES_CREATED+=("$1"); }
track_iptables_rule() { IPTABLES_RULES+=("$1"); }
track_process() { PROCESSES_CREATED+=("$1"); }

cleanup() {
    echo "=== CLEANUP ==="
    for pid in "${PROCESSES_CREATED[@]}"; do
        kill -9 "$pid" 2>/dev/null || true
    done
    sleep 2
    for iface in "${INTERFACES_CREATED[@]}"; do
        ip link set "$iface" down 2>/dev/null || true
        if [[ "$iface" == "$BRIDGE" ]]; then
            ip link del "$iface" type bridge 2>/dev/null || true
        else
            ip tuntap del dev "$iface" mode tap 2>/dev/null || true
        fi
    done
    for rule in "${IPTABLES_RULES[@]}"; do
        iptables $rule 2>/dev/null || true
    done
    for file in "${FILES_CREATED[@]}"; do
        rm -rf "$file" 2>/dev/null || true
    done
}

[[ $EUID -ne 0 ]] && echo "ERROR: Run as root" && exit 1

KEEP_DISK=false
ENABLE_SSH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        -k|--keep-disk) KEEP_DISK=true; shift ;;
        -s|--ssh) ENABLE_SSH=true; shift ;;
        -p|--port) FORWARD_PORTS+=("$2"); shift 2 ;;
        -c|--cleanup) trap - EXIT; cleanup; exit 0 ;;
        *) shift ;;
    esac
done

trap cleanup EXIT

find_bios() {
    for p in "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" "/usr/share/AAVMF/AAVMF_CODE.fd" "/usr/share/edk2/aarch64/QEMU_EFI.fd"; do
        [[ -f "$p" ]] && echo "$p" && return 0
    done
    return 1
}

BIOS=$(find_bios) || { echo "ERROR: No UEFI firmware"; exit 1; }

echo "Cleaning up any existing network interfaces..."
pkill -9 qemu-system-aarch64 2>/dev/null || true
sleep 1

ip link set "$TAP" down 2>/dev/null || true
ip link set "$TAP" nomaster 2>/dev/null || true
ip tuntap del dev "$TAP" mode tap 2>/dev/null || true
ip link del "$TAP" 2>/dev/null || true

ip link set "$BRIDGE" down 2>/dev/null || true
for member in $(bridge link show 2>/dev/null | grep "$BRIDGE" | awk '{print $2}' | cut -d'@' -f1); do
    ip link set "$member" nomaster 2>/dev/null || true
done
ip link del "$BRIDGE" type bridge 2>/dev/null || true

# Clean iptables
iptables -t nat -D POSTROUTING -s "$NETWORK" -o "$INTERNET_IF" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$BRIDGE" -o "$INTERNET_IF" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$INTERNET_IF" -o "$BRIDGE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport "$GDB_PORT" -j DNAT --to-destination "${VM_IP}:${GDB_PORT}" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$VM_IP" --dport "$GDB_PORT" -j ACCEPT 2>/dev/null || true

sleep 1

if [[ ! -f "$VM_QCOW2" ]]; then
    qemu-img create -f qcow2 "$VM_QCOW2" 25G
    [[ "$KEEP_DISK" == false ]] && track_file "$VM_QCOW2"
fi

if [[ ! -f "$VM_ISO" ]]; then
    wget -q --show-progress "$ISO_URL" -O "$VM_ISO"
    track_file "$VM_ISO"
fi

# Create Alpine answers file for automated installation
cat > "$ANSWERS_FILE" << 'EOF'
KEYMAPOPTS="us us"
HOSTNAMEOPTS="-n alpine-vm"
INTERFACESOPTS="auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 172.20.0.10
    netmask 255.255.255.0
    gateway 172.20.0.1
"
DNSOPTS="-d alpine.local 8.8.8.8"
TIMEZONEOPTS="-z UTC"
PROXYOPTS="none"
APKREPOSOPTS="-1"
SSHDOPTS="-c openssh -k yes"
NTPOPTS="-c chrony"
DISKOPTS="-m sys /dev/vda"
EOF

track_file "$ANSWERS_FILE"

echo "Creating bridge..."
ip link add name "$BRIDGE" type bridge
track_interface "$BRIDGE"
ip addr add "$GATEWAY/$NETMASK" dev "$BRIDGE"
ip link set "$BRIDGE" up

echo "Creating TAP..."
ip tuntap add dev "$TAP" mode tap
track_interface "$TAP"
ip link set "$TAP" master "$BRIDGE"
ip link set "$TAP" up
ip link set "$TAP" promisc on

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.forwarding=1 >/dev/null
sysctl -w net.ipv4.conf.$BRIDGE.forwarding=1 >/dev/null
sysctl -w net.ipv4.conf.$TAP.forwarding=1 >/dev/null

# NAT rules
iptables -t nat -A POSTROUTING -s "$NETWORK" -o "$INTERNET_IF" -j MASQUERADE
track_iptables_rule "-t nat -D POSTROUTING -s $NETWORK -o $INTERNET_IF -j MASQUERADE"

iptables -A FORWARD -i "$BRIDGE" -o "$INTERNET_IF" -j ACCEPT
track_iptables_rule "-D FORWARD -i $BRIDGE -o $INTERNET_IF -j ACCEPT"

iptables -A FORWARD -o "$BRIDGE" -i "$INTERNET_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
track_iptables_rule "-D FORWARD -o $BRIDGE -i $INTERNET_IF -m state --state RELATED,ESTABLISHED -j ACCEPT"

# Allow all traffic on bridge
iptables -A FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
track_iptables_rule "-D FORWARD -i $BRIDGE -o $BRIDGE -j ACCEPT"

# GDB port forwarding (ALWAYS enabled)
echo "Setting up GDB port forwarding: localhost:$GDB_PORT -> VM:$GDB_PORT"
iptables -t nat -A PREROUTING -p tcp --dport "$GDB_PORT" -j DNAT --to-destination "${VM_IP}:${GDB_PORT}"
track_iptables_rule "-t nat -D PREROUTING -p tcp --dport $GDB_PORT -j DNAT --to-destination ${VM_IP}:${GDB_PORT}"

iptables -A FORWARD -p tcp -d "$VM_IP" --dport "$GDB_PORT" -j ACCEPT
track_iptables_rule "-D FORWARD -p tcp -d $VM_IP --dport $GDB_PORT -j ACCEPT"

# Additional custom port forwarding
for port in "${FORWARD_PORTS[@]}"; do
    echo "Forwarding port: localhost:$port -> VM:$port"
    iptables -t nat -A PREROUTING -p tcp --dport "$port" -j DNAT --to-destination "${VM_IP}:${port}"
    track_iptables_rule "-t nat -D PREROUTING -p tcp --dport $port -j DNAT --to-destination ${VM_IP}:${port}"
    
    iptables -A FORWARD -p tcp -d "$VM_IP" --dport "$port" -j ACCEPT
    track_iptables_rule "-D FORWARD -p tcp -d $VM_IP --dport $port -j ACCEPT"
done

echo "✓ Network ready"

QEMU_CMD="qemu-system-aarch64 -machine virt,accel=tcg -cpu $CPU -smp cores=$CORES -m $MEM"
QEMU_CMD+=" -bios $BIOS"
QEMU_CMD+=" -drive file=$VM_QCOW2,format=qcow2,if=virtio -cdrom $VM_ISO"
QEMU_CMD+=" -netdev tap,id=net0,ifname=$TAP,script=no,downscript=no"
QEMU_CMD+=" -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56"

[[ "$ENABLE_SSH" == true ]] && QEMU_CMD+=" -netdev user,id=net1,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net1"

QEMU_CMD+=" -nographic"

cat << EOF

╔═══════════════════════════════════════════════════════════╗
║  ALPINE ARM64 VM - AUTOMATED INSTALL                      ║
╠═══════════════════════════════════════════════════════════╣
║                                                           ║
║  PORT FORWARDING:                                         ║
║    ✓ GDB: localhost:$GDB_PORT -> VM:$GDB_PORT (always on)              ║
EOF

for port in "${FORWARD_PORTS[@]}"; do
    printf "║    ✓ localhost:%-5s -> VM:%-5s                        ║\n" "$port" "$port"
done

cat << 'EOF'
║                                                           ║
║  INSTRUCTIONS:                                            ║
║                                                           ║
║  1. Login: root [ENTER] [ENTER] (no password)            ║
║                                                           ║
║  2. Set password first:                                   ║
║     passwd                                                ║
║     (enter: alpine twice)                                 ║
║                                                           ║
║  3. Fix network manually:                                 ║
║     ifconfig eth0 172.20.0.10 netmask 255.255.255.0       ║
║     route add default gw 172.20.0.1                       ║
║     echo "nameserver 8.8.8.8" > /etc/resolv.conf         ║
║     ping 8.8.8.8                                          ║
║                                                           ║
║  4. Fix repositories:                                     ║
║     cat > /etc/apk/repositories << 'REPOS'               ║
║     https://dl-cdn.alpinelinux.org/alpine/v3.23/main     ║
║     https://dl-cdn.alpinelinux.org/alpine/v3.23/community║
║     REPOS                                                 ║
║     apk update                                            ║
║                                                           ║
║  5. Install to disk:                                      ║
║     apk add e2fsprogs                                     ║
║     setup-disk -m sys /dev/vda                            ║
║                                                           ║
║  6. For GDB debugging (after installation):               ║
║     apk add gdb                                           ║
║     gdbserver :1234 ./your_program                        ║
║     On host: gdb-multiarch                                ║
║              target remote localhost:1234                 ║
║                                                           ║
║  7. Reboot, Ctrl+C, next time: -k flag                    ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝

Press ENTER to start...
EOF

read -r < /dev/tty || true

exec $QEMU_CMD
