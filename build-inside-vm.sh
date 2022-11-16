#!/bin/bash
# build-inside-vm.sh builds the images (cloud image, vagrant boxes)

# nounset: "Treat unset variables and parameters [...] as an error when performing parameter expansion."
# errexit: "Exit immediately if [...] command exits with a non-zero status."
set -o nounset -o errexit
shopt -s extglob
readonly DEFAULT_DISK_SIZE="2G"
readonly IMAGE="image.img"
# shellcheck disable=SC2016
readonly REBORN_MIRROR='https://de.mirror.rebornos.org/repo/$repo/os/$arch'

function init() {
  readonly ORIG_PWD="${PWD}"
  readonly OUTPUT="${PWD}/output"
  local tmpdir
  tmpdir="$(mktemp --dry-run --directory --tmpdir="${PWD}/tmp")"
  readonly TMPDIR="${tmpdir}"
  mkdir -p "${OUTPUT}" "${TMPDIR}"
  if [ -n "${SUDO_UID:-}" ] && [[ -n "${SUDO_GID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${OUTPUT}" "${TMPDIR}"
  fi
  cd "${TMPDIR}"

  readonly MOUNT="${PWD}/mount"
  mkdir "${MOUNT}"
}

# Do some cleanup when the script exits
function cleanup() {
  # We want all the commands to run, even if one of them fails.
  set +o errexit
  if [ -n "${LOOPDEV:-}" ]; then
    losetup -d "${LOOPDEV}"
  fi
  if [ -n "${MOUNT:-}" ] && mountpoint -q "${MOUNT}"; then
    # We do not want risking deleting ex: the package cache
    umount --recursive "${MOUNT}" || exit 1
  fi
  if [ -n "${TMPDIR:-}" ]; then
    rm -rf "${TMPDIR}"
  fi
}
trap cleanup EXIT

# Create the disk, partitions it, format the partition and mount the filesystem
function setup_disk() {
  truncate -s "${DEFAULT_DISK_SIZE}" "${IMAGE}"
  LOOPDEV=$(losetup --find --partscan --show "${IMAGE}")
  parted -s "${LOOPDEV}" mklabel msdos
  parted -s "${LOOPDEV}" mkpart primary fat32 0% 100M
  parted -s "${LOOPDEV}" set 1 esp on
  parted -s "${LOOPDEV}" mkpart primary btrfs 100M 100%

  # Partscan is racy
  wait_until_settled "${LOOPDEV}"
  mkfs.fat -F 32 "${LOOPDEV}p1"
  mkfs.btrfs "${LOOPDEV}p2"
  mount -o compress=zstd "${LOOPDEV}p2" "${MOUNT}"
  mount --mkdir "${LOOPDEV}p1" "${MOUNT}/efi"
}


# Install Arch Linux to the filesystem (bootstrap)
function bootstrap() {
  cat <<EOF >pacman.conf
[options]

Architecture = aarch64
SigLevel = Never
ParallelDownloads = 6

[RebornOS]
Server = ${REBORN_MIRROR}

[core]
Include = mirrorlist

[extra]
Include = mirrorlist

[community]
Include = mirrorlist

[alarm]
Include = mirrorlist

[aur]
Include = mirrorlist
EOF
  rate-mirrors archarm >> mirrorlist
  cat <<EOF >pacman.conf.machine
#
# /etc/pacman.conf
#
# See the pacman.conf(5) manpage for option and repository directives

#
# GENERAL OPTIONS
#
[options]
#IgnorePkg =
# The following paths are commented out with their default values listed.
# If you wish to use different paths, uncomment and update the paths.
#RootDir     = /
#DBPath      = /var/lib/pacman/
#CacheDir    = /var/cache/pacman/pkg/
#LogFile     = /var/log/pacman.log
#GPGDir      = /etc/pacman.d/gnupg/
#HookDir     = /etc/pacman.d/hooks/
HoldPkg     = pacman glibc
#XferCommand = /usr/bin/curl -L -C - -f -o %o %u
#XferCommand = /usr/bin/wget --passive-ftp -c -O %o %u
#CleanMethod = KeepInstalled
Architecture = aarch64

# Pacman won't upgrade packages listed in IgnorePkg and members of IgnoreGroup
#IgnorePkg   =
#IgnoreGroup =

#NoUpgrade   =
#NoExtract   =

# Misc options
#UseSyslog
Color
ILoveCandy
#NoProgressBar
#CheckSpace
#VerbosePkgLists
ParallelDownloads = 5
# By default, pacman accepts packages signed by keys that its local keyring
# trusts (see pacman-key and its man page), as well as unsigned packages.
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
#RemoteFileSigLevel = Required

#
# REPOSITORIES
#   - can be defined here or included from another file
#   - pacman will search repositories in the order defined here
#   - local/custom mirrors can be added here or in separate files
#   - repositories listed first will take precedence when packages
#     have identical names, regardless of version number
#   - URLs will have $ repo replaced by the name of the current repo
#   - URLs will have $ arch replaced by the name of the architecture
#
# Repository entries are of the format:
#       [repo-name]
#       Server = ServerName
#       Include = IncludePath
#
# The header [repo-name] is crucial - it must be present and
# uncommented to enable the repo.
#

# The testing repositories are disabled by default. To enable, uncomment the
# repo name header and Include lines. You can add preferred servers immediately
# after the header, and they will be used before the default mirrors.

[RebornOS]
Include = /etc/pacman.d/reborn-mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[community]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist

[aur]
Include = /etc/pacman.d/mirrorlist

# An example of a custom package repository.  See the pacman manpage for
# tips on creating your own repositories.
#[custom]
#SigLevel = Optional TrustAll
#Server = file:///home/custompkgs
EOF

  # We use the hosts package cache
  pacstrap -c -C pacman.conf -M "${MOUNT}" base linux-aarch64 grub dosfstools efibootmgr openssh sudo btrfs-progs archlinuxarm-keyring rebornos-keyring rebornos-mirrorlist rebornos-os-release lsb-release rate-mirrors
  cp mirrorlist "${MOUNT}/etc/pacman.d/"
  cp pacman.conf.machine "${MOUNT}/etc/pacman.conf"
}

# Cleanup the image and trim it
function image_cleanup() {
  # Remove pacman key ring for re-initialization
  rm -rf "${MOUNT}/etc/pacman.d/gnupg/"

  # The mkinitcpio autodetect hook removes modules not needed by the
  # running system from the initramfs. This make the image non-bootable
  # on some systems as initramfs lacks the relevant kernel modules.
  # Ex: Some systems need the virtio-scsi kernel module and not the
  # "autodetected" virtio-blk kernel module for disk access.
  #
  # So for the initial install we use the fallback initramfs, and
  # "autodetect" should add the relevant modules to the initramfs when
  # the user updates the kernel.
  cp --reflink=always -a "${MOUNT}/boot/"{initramfs-linux-fallback.img,initramfs-linux.img}

  sync -f "${MOUNT}/etc/os-release"
  fstrim --verbose "${MOUNT}"
}

# Helper function: wait until a given loop device has settled
# ${1} - loop device
function wait_until_settled() {
  udevadm settle
  blockdev --flushbufs --rereadpt "${1}"
  until test -e "${1}p2"; do
    echo "${1}p2 doesn't exist yet..."
    sleep 1
  done
}

# Mount image helper (loop device + mount)
function mount_image() {
  LOOPDEV=$(losetup --find --partscan --show "${1:-${IMAGE}}")
  # Partscan is racy
  wait_until_settled "${LOOPDEV}"
  mount -o compress-force=zstd "${LOOPDEV}p2" "${MOUNT}"
  # Setup bind mount to package cache
  mount --bind "/var/cache/pacman/pkg" "${MOUNT}/var/cache/pacman/pkg"
}

# Unmount image helper (umount + detach loop device)
function unmount_image() {
  umount --recursive "${MOUNT}"
  losetup -d "${LOOPDEV}"
  LOOPDEV=""
}

# Compute SHA256, adjust owner to $SUDO_UID:$SUDO_UID and move to output/
function mv_to_output() {
  sha256sum "${1}" >"${1}.SHA256"
  if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "${1}"{,.SHA256}
  fi
  mv "${1}"{,.SHA256} "${OUTPUT}/"
}

# Helper function: create a new image from the "base" image
# ${1} - final file
# ${2} - pre
# ${3} - post
function create_image() {
  local tmp_image
  tmp_image="$(basename "$(mktemp -u)")"
  cp -a "${IMAGE}" "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    truncate -s "${DISK_SIZE}" "${tmp_image}"
    # make partition table extend to the end of the disk
    parted -s "${tmp_image}" resizepart 2 100%
  fi
  mount_image "${tmp_image}"
  if [ -n "${DISK_SIZE}" ]; then
    btrfs filesystem resize max "${MOUNT}"
  fi

  if [ 0 -lt "${#PACKAGES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/pacman -S --noconfirm "${PACKAGES[@]}"
  fi
  if [ 0 -lt "${#SERVICES[@]}" ]; then
    arch-chroot "${MOUNT}" /usr/bin/systemctl enable "${SERVICES[@]}"
  fi
  "${2}"
  image_cleanup
  unmount_image
  "${3}" "${tmp_image}" "${1}"
  mv_to_output "${1}"
}


# ${1} - Optional build version. If not set, will generate a default based on date.
function main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "root is required"
    exit 1
  fi
  # if build version env value is set print it
  if [ -n "${BUILD_VERSION:-}" ]; then
    echo "Build version: ${BUILD_VERSION}"
  fi
  printf "Running initial setup...\n"
  init
  printf "Running setup_disk...\n"
  setup_disk
  printf "Running bootstrap...\n"
  bootstrap
  # shellcheck source=images/base.sh
  source "${ORIG_PWD}/images/base.sh"
  pre
  unmount_image

  local build_version
  if [ -z "${1:-}" ]; then
    build_version="$(date +%Y-%m-%d)"
    echo "WARNING: BUILD_VERSION wasn't set!"
    echo "Falling back to $build_version"
  else
    build_version="${1}"
  fi

  # shellcheck source=images/common.sh
  source "${ORIG_PWD}/images/common.sh"
  for image in "${ORIG_PWD}/images/"!(base|common).sh; do
    # shellcheck source=/dev/null
    source "${image}"
    create_image "${IMAGE_NAME}" pre post
  done
}
main "$@"
