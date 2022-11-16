#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="RebornOS-ARM-generic-minimal-${build_version}.qcow2"
# It is meant for local usage so the disk should be "big enough".
DISK_SIZE="40G"
PACKAGES=(networkmanager nano vim wget yay qemu-guest-agent spice-vdagent)
SERVICES=(NetworkManager.service)

function pre() {
  local NEWUSER="rebornos"
  echo "Building minimal image"
  arch-chroot "${MOUNT}" /usr/bin/useradd -m -U "${NEWUSER}" -G wheel
  echo -e "${NEWUSER}\n${NEWUSER}" | arch-chroot "${MOUNT}" /usr/bin/passwd "${NEWUSER}"
  echo "${NEWUSER} ALL=(ALL) NOPASSWD: ALL" >"${MOUNT}/etc/sudoers.d/${NEWUSER}"
  # allow wheel group to use sudo
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" >"${MOUNT}/etc/sudoers.d/10-wheel"
  printf "y\ny\n" | arch-chroot "${MOUNT}" /usr/bin/pacman -Scc
  rm "${MOUNT}/etc/machine-id"
}

function post() {
  qemu-img convert -c -f raw -O qcow2 "${1}" "${2}"
  rm "${1}"
}
