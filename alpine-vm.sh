#!/data/data/com.termux/files/usr/bin/bash
set -e

ALPINE_VERSION="3.20"
ALPINE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"
ISO_DIR_URL="${ALPINE_BASE_URL}/releases/aarch64"

VMDIR="$HOME/alpine-vm"
DISK="$VMDIR/alpine.qcow2"
ISO="$VMDIR/alpine.iso"
CODE_FW="$PREFIX/share/qemu/edk2-aarch64-code.fd"
VARS_FW="$VMDIR/edk2-aarch64-vars.fd"
DISK_SIZE="8G"
RAM="2048"
CPUS="2"

QEMU_BIN="qemu-system-aarch64"
QEMU_IMG_BIN="qemu-img"

install_qemu() {
    pkg update -y
    pkg upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    pkg install -y qemu-system-aarch64-headless qemu-utils wget expect
}

resolve_iso_filename() {
    wget -qO- "${ISO_DIR_URL}/latest-releases.yaml" \
        | grep -E '^\s*file:\s*alpine-virt-[0-9.]+-aarch64\.iso\s*$' \
        | head -n1 \
        | awk '{print $2}'
}

do_init() {
    if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
        install_qemu
    else
        echo "QEMU already installed, skipping."
    fi

    mkdir -p "$VMDIR"

    if [ ! -f "$ISO" ]; then
        echo ">>> Resolving current Alpine ${ALPINE_VERSION} aarch64 ISO filename..."
        ISO_FILE="$(resolve_iso_filename)"
        if [ -z "$ISO_FILE" ]; then
            echo "Could not resolve ISO filename from ${ISO_DIR_URL}/latest-releases.yaml" >&2
            exit 1
        fi
        echo ">>> Downloading ${ISO_FILE}..."
        wget -O "$ISO" "${ISO_DIR_URL}/${ISO_FILE}"
    fi

    if [ ! -f "$DISK" ]; then
        "$QEMU_IMG_BIN" create -f qcow2 "$DISK" "$DISK_SIZE"
    fi

    if [ ! -f "$CODE_FW" ]; then
        echo "Expected UEFI firmware not found at $CODE_FW" >&2
        echo "Check 'pkg list-files qemu-system-aarch64-headless' for the actual path." >&2
        exit 1
    fi

    if [ ! -f "$VARS_FW" ]; then
        # NVRAM vars file must match the code file's size exactly.
        FW_SIZE=$(stat -c%s "$CODE_FW")
        dd if=/dev/zero of="$VARS_FW" bs=1 count=0 seek="$FW_SIZE" 2>/dev/null
    fi

    echo "Init complete. Run with --start to boot the VM."
}

do_start() {
    if ! command -v "$QEMU_BIN" >/dev/null 2>&1 || [ ! -f "$DISK" ] || [ ! -f "$ISO" ] || [ ! -f "$VARS_FW" ]; then
        echo "VM not initialized. Run with --init first."
        exit 1
    fi

    echo ">>> Booting VM (stateless: -snapshot enabled, disk changes are discarded on exit)..."

    expect -c "
    set timeout -1
    spawn $QEMU_BIN -machine virt -cpu max -m $RAM -smp cpus=$CPUS \
        -drive if=pflash,format=raw,readonly=on,file=$CODE_FW \
        -drive if=pflash,format=raw,file=$VARS_FW \
        -drive file=$DISK,if=virtio,format=qcow2 -snapshot \
        -cdrom $ISO \
        -netdev user,id=n1,dns=8.8.8.8,hostfwd=tcp::2222-:22 \
        -device virtio-net-pci,netdev=n1 -nographic

    expect \"localhost login:\"
    send \"root\r\"

    expect \"localhost:~#\"
    send \"ip link set dev eth0 up\r\"

    expect \"localhost:~#\"
    send \"udhcpc\r\"

    expect \"localhost:~#\"
    send \"echo http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main >> /etc/apk/repositories\r\"

    expect \"localhost:~#\"
    send \"echo http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community >> /etc/apk/repositories\r\"

    expect \"localhost:~#\"
    send \"apk update\r\"

    expect \"localhost:~#\"
    send \"apk add docker openrc\r\"

    expect \"localhost:~#\"
    send \"rc-service cgroups start\r\"

    expect \"localhost:~#\"
    send \"rc-service docker start --nodeps\r\"

    expect \"localhost:~#\"
    send \"until \\[ -S /var/run/docker.sock \\]; do sleep 1; done\r\"

    expect \"localhost:~#\"
    send \"docker run --rm hello-world\r\"

    interact
    "
}

do_clean() {
    rm -rf "$VMDIR"
    echo "VM files removed. Run with --init to set up again."
}

case "$1" in
    --init)
        do_init
        ;;
    --start)
        do_start
        ;;
    --clean)
        do_clean
        ;;
    *)
        echo "Usage: $0 --init|--start|--clean"
        exit 1
        ;;
esac
