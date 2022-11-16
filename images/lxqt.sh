#!/bin/bash
# shellcheck disable=SC2034,SC2154
IMAGE_NAME="RebornOS-ARM-generic-lxqt-${build_version}.qcow2"
# It is meant for local usage so the disk should be "big enough".
DISK_SIZE="40G"
PACKAGES=(NetworkManager nano vim wget yay rebornos-cosmic-lxqt network-manager-applet rebornos-grub2-theme-vimix-git-fix rebornos-plymouth-theme)
SERVICES=(NetworkManager.service sddm-plymouth.service)

function pre() {
    local NEWUSER="rebornos"
    arch-chroot "${MOUNT}" /usr/bin/useradd -m -U "${NEWUSER}" -G wheel
    echo -e "${NEWUSER}\n${NEWUSER}" | arch-chroot "${MOUNT}" /usr/bin/passwd "${NEWUSER}"
    echo "${NEWUSER} ALL=(ALL) NOPASSWD: ALL" >"${MOUNT}/etc/sudoers.d/${NEWUSER}"
    echo "%wheel ALL=(ALL) NOPASSWD: ALL" >"${MOUNT}/etc/sudoers.d/10-wheel"
    printf "y\ny\n" | arch-chroot "${MOUNT}" /usr/bin/pacman -Scc
    cat <<EOF >"${MOUNT}/etc/plymouth/plymouthd.conf"
# Set your plymouth configuration here.
[Daemon]
Theme=reborn
ShowDelay=0
DeviceTimeout=8
EOF
    echo "GRUB_THEME=\"/boot/grub/themes/Vimix/theme.txt\"" >>"${MOUNT}/etc/default/grub"
    sed -Ei 's/^(GRUB_CMDLINE_LINUX_DEFAULT=.*)"$/\1 splash"/' "${MOUNT}/etc/default/grub"
    arch-chroot "${MOUNT}" grub-mkconfig -o /boot/grub/grub.cfg
    sed -i "s|${LOOPDEV}p2|PARTUUID=$(blkid -s PARTUUID -o value "${LOOPDEV}p2")|" "${MOUNT}/boot/grub/grub.cfg"
    sed -i 's/^HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck plymouth)/' "${MOUNT}/etc/mkinitcpio.conf"
    arch-chroot "${MOUNT}" mkinitcpio -p linux
}

function post() {
  qemu-img convert -c -f raw -O qcow2 "${1}" "${2}"
  rm "${1}"
}