#!/bin/bash

# Misc "tweaks" done after bootstrapping
function pre() {
  # Remove machine-id see:
  # https://gitlab.archlinux.org/archlinux/arch-boxes/-/issues/25
  # https://gitlab.archlinux.org/archlinux/arch-boxes/-/issues/117
  rm "${MOUNT}/etc/machine-id"
  # add EFI part to fstab
  printf 'UUID=%s /efi vfat noauto,x-systemd.automount,x-systemd.idle-timeout=300,rw,relatime,fmask=0133,dmask=0022,utf8   0 2\n' "$(blkid -s UUID -o value "${LOOPDEV}p1")" >>"${MOUNT}/etc/fstab"
  printf 'UUID=%s / btrfs defaults,discard=async 0 2\n' "$(blkid -s UUID -o value "${LOOPDEV}p2")" >>"${MOUNT}/etc/fstab"

  arch-chroot "${MOUNT}" /usr/bin/btrfs subvolume create /swap
  chattr +C "${MOUNT}/swap"
  chmod 0700 "${MOUNT}/swap"
  fallocate -l 512M "${MOUNT}/swap/swapfile"
  chmod 0600 "${MOUNT}/swap/swapfile"
  mkswap -U clear "${MOUNT}/swap/swapfile"
  echo -e "/swap/swapfile none swap defaults 0 0" >>"${MOUNT}/etc/fstab"
  # Uncomment C.UTF-8 for inclusion in generation
  sed -i 's/^#C.UTF-8 UTF-8/C.UTF-8 UTF-8/' "${MOUNT}/etc/locale.gen"
  arch-chroot "${MOUNT}" /usr/bin/locale-gen
  arch-chroot "${MOUNT}" /usr/bin/systemd-firstboot --locale=C.UTF-8 --timezone=UTC --hostname=rebornos --keymap=us
  ln -sf /run/systemd/resolve/stub-resolv.conf "${MOUNT}/etc/resolv.conf"

  # Setup pacman-init.service for clean pacman keyring initialization
  cat <<EOF >"${MOUNT}/etc/systemd/system/pacman-init.service"
[Unit]
Description=Initializes Pacman keyring
Before=sshd.service cloud-final.service archlinux-keyring-wkd-sync.service
After=time-sync.target
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/pacman-key --init
ExecStart=/usr/bin/pacman-key --populate

[Install]
WantedBy=multi-user.target
EOF

  # Add service for running reflector on first boot
  cat <<EOF >"${MOUNT}/etc/systemd/system/rate-mirrors-init.service"
[Unit]
Description=Initializes mirrors for the VM
After=network-online.target
Wants=network-online.target
Before=sshd.service cloud-final.service
ConditionFirstBoot=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=rate-mirrors --allow-root --save=/etc/pacman.d/mirrorlist archarm

[Install]
WantedBy=multi-user.target
EOF

  # enabling important services
  arch-chroot "${MOUNT}" /bin/bash -e <<EOF
source /etc/profile
systemctl enable sshd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable systemd-timesyncd
systemctl enable systemd-time-wait-sync
systemctl enable pacman-init.service
systemctl enable rate-mirrors-init.service
EOF

  # GRUB
  # Use arm64-efi as the target for UEFI boot
  arch-chroot "${MOUNT}" /usr/bin/grub-install --target=arm64-efi --efi-directory=/efi --removable
  sed -i 's/^GRUB_TIMEOUT=.*$/GRUB_TIMEOUT=1/' "${MOUNT}/etc/default/grub"
  # setup unpredictable kernel names
  sed -i 's/^GRUB_CMDLINE_LINUX=.*$/GRUB_CMDLINE_LINUX="net.ifnames=0"/' "${MOUNT}/etc/default/grub"
  # sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"rootflags=compress-force=zstd\"/' "${MOUNT}/etc/default/grub"
  # Replace GRUB_DISTRIBUTOR with RebornOS
  sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=\"RebornOS\"/' "${MOUNT}/etc/default/grub"
  arch-chroot "${MOUNT}" /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg
}
