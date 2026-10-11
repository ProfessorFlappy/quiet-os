#!/usr/bin/env bash
set -euo pipefail

# Find the newest kernel-core version included in the image.
# Do not use uname -r: that may report the build host's kernel.
KVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core \
    | sort -V | tail -n 1)"

if [[ -z "$KVER" ]]; then
    echo "ERROR: Could not determine the image kernel version." >&2
    exit 1
fi

MODULE_DIR="/usr/lib/modules/${KVER}"
BUILD_DIR="/lib/modules/${KVER}/build"
SRC_DIR="$(mktemp -d)"

trap 'rm -rf "$SRC_DIR"' EXIT

# Install build tools only if needed, then remove newly added packages.
BUILD_PACKAGES=(git gcc make elfutils-libelf-devel)
declare -A WAS_INSTALLED=()

for pkg in "${BUILD_PACKAGES[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        WAS_INSTALLED["$pkg"]=1
    else
        WAS_INSTALLED["$pkg"]=0
    fi
done

# Remember whether the exact matching kernel-devel version was present.
HAD_MATCHING_KERNEL_DEVEL=0

if rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-devel \
    2>/dev/null | grep -Fxq "$KVER"; then
    HAD_MATCHING_KERNEL_DEVEL=1
fi

# Install the exact kernel development package and build tools.
dnf5 install -y "kernel-devel-${KVER}" "${BUILD_PACKAGES[@]}"

# Verify that the expected development files are actually available.
if ! rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-devel \
    2>/dev/null | grep -Fxq "$KVER"; then
    echo "ERROR: kernel-devel for ${KVER} is not installed." >&2
    exit 1
fi

if [[ ! -f "${BUILD_DIR}/Makefile" ]]; then
    echo "ERROR: Kernel build tree not found: ${BUILD_DIR}" >&2
    exit 1
fi

# Fetch the source revision used by the original package.
git clone https://github.com/BeardOverflow/msi-ec.git \
    "${SRC_DIR}/msi-ec"

git -C "${SRC_DIR}/msi-ec" checkout --detach d7fbbd8

# Build against the image kernel, not the host kernel.
make -C "${SRC_DIR}/msi-ec" \
    KERNELRELEASE="${KVER}" \
    modules

MODULE_FILE="${SRC_DIR}/msi-ec/msi-ec.ko"

if [[ ! -s "$MODULE_FILE" ]]; then
    echo "ERROR: Build completed without producing ${MODULE_FILE}." >&2
    exit 1
fi

# Make sure the module was compiled for the intended kernel.
MODULE_VERMAGIC="$(modinfo -F vermagic "$MODULE_FILE")"

if [[ "$MODULE_VERMAGIC" != "$KVER "* ]]; then
    echo "ERROR: Module kernel version does not match the image." >&2
    echo "Expected: ${KVER}" >&2
    echo "Found:    ${MODULE_VERMAGIC}" >&2
    exit 1
fi

# Install the module into the image.
install -D -m 0644 \
    "$MODULE_FILE" \
    "${MODULE_DIR}/updates/drivers/platform/x86/msi-ec.ko"

# Refresh the module dependency database.
depmod -a "${KVER}"

# Load the module automatically at boot.
install -d /etc/modules-load.d
printf '%s\n' msi-ec > /etc/modules-load.d/msi-ec.conf

# Remove only build packages introduced by this script.
REMOVE_PACKAGES=()

for pkg in "${BUILD_PACKAGES[@]}"; do
    if [[ "${WAS_INSTALLED[$pkg]}" == 0 ]]; then
        REMOVE_PACKAGES+=("$pkg")
    fi
done

if [[ "$HAD_MATCHING_KERNEL_DEVEL" == 0 ]]; then
    REMOVE_PACKAGES+=("kernel-devel-${KVER}")
fi

if ((${#REMOVE_PACKAGES[@]})); then
    dnf5 remove -y "${REMOVE_PACKAGES[@]}"
fi

echo "Built and installed msi-ec for ${KVER}."
