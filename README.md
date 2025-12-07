# QEMU ARM64 VM FOR x86_64 LINUX

A script to automate debugging env setup for ARM binaries in x86_64 Linux systems.

## First time usage

```bash
sudo ./qemu-arm64-vm.sh -k -s
```

Then, after landing in the VM's shell:

```bash
ifconfig eth0 172.20.0.10 netmask 255.255.255.0
route add default gw 172.20.0.1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
ping 8.8.8.8
```

That's the bare minimum to begin testing (port 1234 is ALWAYS forwarded by default) without persistence.
Next steps could look like:

```bash
# In VM:
echo 0 > /proc/sys/kernel/randomize_va_space
cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.23/main
https://dl-cdn.alpinelinux.org/alpine/v3.23/community
EOF

apk update
apk add binutils
apk add build-base
apk add python3-dev musl-dev linux-headers py-pip
python3 -m pip install pwn --break-system-packages
apk add gdb
curl -qsL 'https://install.pwndbg.re' | sh -s -- -t pwndbg-gdb

gdbserver :1234 ./your_binary

# On host: 
gdb-multiarch
(gdb) set architecture aarch64
(gdb) target remote localhost:1234


# To add your binary:
## On VM:
apk add openssh
rc-update add sshd
rc-service sshd start
passwd   # set root password if none
sed -i -e 's/^#*PermitRootLogin.*/PermitRootLogin yes/' -e 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 
rc-service sshd restart

## On host:
scp -P 22 <target_file_path> root@172.20.0.10:<destination_path>


# To close the VM
poweroff
```

## Help

```bash
QEMU Alpine ARM64 VM Setup Script

USAGE:
    sudo ./qemu-arm64-vm.sh [OPTIONS]

OPTIONS:
    -h, --help       Show this help message
    -k, --keep-disk  Keep VM disk after cleanup (use for installed systems)
    -s, --ssh        Enable SSH port forwarding (host:2222 -> VM:22)
    -p, --port PORT  Forward additional port (can be used multiple times)
    -c, --cleanup    Cleanup network resources and exit

NETWORK CONFIGURATION:
    VM IP:      172.20.0.10/24
    Gateway:    172.20.0.1
    Bridge:     br0
    TAP:        tap0
    Network:    172.20.0.0/24
    DNS:        8.8.8.8

PORT FORWARDING:
    GDB Port:   localhost:1234 -> VM:1234 (always enabled)
    SSH Port:   localhost:2222 -> VM:22 (with -s flag)
    Custom:     Use -p flag for additional ports

EXAMPLES:
    # First run (installation)
    sudo ./qemu-arm64-vm.sh

    # After installation (keep disk)
    sudo ./qemu-arm64-vm.sh -k

    # With SSH access
    sudo ./qemu-arm64-vm.sh -k -s

    # With custom port forwarding
    sudo ./qemu-arm64-vm.sh -k -p 8080 -p 3000

    # GDB debugging
    sudo ./qemu-arm64-vm.sh -k
    # In VM: gdbserver :1234 ./program
    # On host: gdb-multiarch
    #          (gdb) target remote localhost:1234

    # Cleanup only
    sudo ./qemu-arm64-vm.sh -c

REQUIREMENTS:
    - Root privileges (sudo)
    - qemu-system-aarch64
    - qemu-efi-aarch64 or AAVMF
    - Bridge utilities
    - iptables

```

## Complete installation flow guidelines

```bash
╔═══════════════════════════════════════════════════════════╗
║  ALPINE ARM64 VM - AUTOMATED INSTALL                      ║
╠═══════════════════════════════════════════════════════════╣
║                                                           ║
║  PORT FORWARDING:                                         ║
║    ✓ GDB: localhost:1234 -> VM:1234 (always on)              ║
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
```

## Quick fixes

If you encounter errors when lauching, it may be that similarly-named interfaces as the ones used by the script are already present on the local system.
If it's not disrupting other implementations on your system, you could do:

```bash
# Automatic
sudo ./qemu-arm64-vm.sh -c

# Manual
sudo ip link set tap0 down
sudo ip link delete tap0
sudo ip link set br0 down
sudo ip link delete br0 type bridge
```
