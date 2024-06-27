#!/bin/bash

export DISTRO="server"
export RELEASE="noble" # Ubuntu release name
export USB=/dev/sdf
export PASSWORD="test"  # temporary root password & password for ${USERNAME}
export HOSTNAME="the-server"          # hostname of the new machine
export USERNAME="user"          # user to create in the new machine
export MOUNTPOINT="/mnt"          # debootstrap target location
export LOCALE="en_US.UTF-8"       # New install language setting.
export TIMEZONE="America/Denver"     # New install timezone setting.

export SSH_PUBLIC_KEY="" # Add your public key here

DISKIDS=(/dev/disk/by-id/ /dev/disk/by-id/) # Add disk by-id's here

## Auto-reboot at the end of installation? (true/false)
REBOOT="false"
POOLNAME="zroot" #"${POOLNAME}" is the default name used in the HOW TO from ZFSBootMenu. You can change it to whateven you want

export APT="/usr/bin/apt"

swapoff --all

git_check() {
  if [[ ! -x /usr/bin/git ]]; then
    apt install -y git
  fi
}

source /etc/os-release
export ID
export BOOT_PART="1"
export BOOT_DEVICE="${USB}-part${BOOT_PART}"

initialize() {
  apt update
  apt install -y debootstrap gdisk zfsutils-linux vim git curl
  zgenhostid -f 0x00bab10c
}

# Disk preparation
disk_prepare() {
  wipefs -a "${USB}"
  sgdisk --zap-all "${USB}"
  sync
  sleep 2

  sgdisk -n "1:1m:+30000m" -t "1:EF00" "${USB}"
  sync
  sleep 2

}

# ZFS pool creation
zfs_pool_create() {
  echo "------------> Create zpool <------------"

  # Convert array to a space-separated string
  DISKIDSTR="${DISKIDS[*]}"

  zpool create -f -o ashift=12 \
      -O compression=lz4 \
      -O acltype=posixacl \
      -O xattr=sa \
      -O relatime=on \
      -O atime=off \
      -O checksum=sha256 \
      -o autotrim=on \
      -o compatibility=openzfs-2.1-linux \
      -m none "${POOLNAME}" raidz1 $DISKIDSTR

  sync
  sleep 2

  # Create initial file systems
  zfs create -o mountpoint=/ -o canmount=noauto  "${POOLNAME}"/ubuntu
  sync
  sleep 2
  zfs create -o mountpoint=/home "${POOLNAME}"/home
  sync
  sleep 2
  zfs create -o mountpoint=/root "${POOLNAME}"/ubuntu/root
  sync
  sleep 2


  zpool set bootfs="${POOLNAME}"/ubuntu "${POOLNAME}"

  # Export, then re-import with a temporary mountpoint of "${MOUNTPOINT}"
  zpool export "${POOLNAME}"
  zpool import -N -R "${MOUNTPOINT}" "${POOLNAME}"

  zfs mount "${POOLNAME}"/ubuntu
  zfs mount "${POOLNAME}"/home
  zfs mount "${POOLNAME}"/ubuntu/root

  # Update device symlinks
  udevadm trigger
}

# Install Ubuntu
ubuntu_debootstrap() {
  echo "------------> Debootstrap Ubuntu ${RELEASE} <------------"
  debootstrap ${RELEASE} "${MOUNTPOINT}"

  # Copy files into the new install
  cp /etc/hostid "${MOUNTPOINT}"/etc/hostid
  cp /etc/resolv.conf "${MOUNTPOINT}"/etc/
  mkdir "${MOUNTPOINT}"/etc/zfs

  # Chroot into the new OS
  mount -t proc proc "${MOUNTPOINT}"/proc
  mount -t sysfs sys "${MOUNTPOINT}"/sys
  mount -B /dev "${MOUNTPOINT}"/dev
  mount -t devpts pts "${MOUNTPOINT}"/dev/pts

  # Set a hostname
  echo "$HOSTNAME" >"${MOUNTPOINT}"/etc/hostname
  echo "127.0.1.1       $HOSTNAME" >>"${MOUNTPOINT}"/etc/hosts

  # Set root passwd
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  echo -e "root:$PASSWORD" | chpasswd -c SHA256
EOCHROOT

  # Set up APT sources
  cat <<EOF >"${MOUNTPOINT}"/etc/apt/sources.list
# Uncomment the deb-src entries if you need source packages

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-backports main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-backports main restricted universe multiverse
EOF

  # Update the repository cache and system, install base packages, set up
  # console properties
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  ${APT} update
  ${APT} upgrade -y
  ${APT} install -y --no-install-recommends linux-generic locales console-setup git htop openssh-server
EOCHROOT

  chroot "$MOUNTPOINT" /bin/bash -x <<-EOCHROOT
		##4.5 configure basic system
		locale-gen en_US.UTF-8 $LOCALE
		echo 'LANG="$LOCALE"' > /etc/default/locale

		##set timezone
		ln -fs /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
    # TODO: Make the reconfigurations below selectable by variables
	#	#dpkg-reconfigure locales tzdata keyboard-configuration console-setup
    #dpkg-reconfigure keyboard-configuration
EOCHROOT

  # ZFS Configuration
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  ${APT} install -y dosfstools zfs-initramfs zfsutils-linux curl vim wget git
  systemctl enable zfs.target
  systemctl enable zfs-import-cache
  systemctl enable zfs-mount
  systemctl enable zfs-import.target
  echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
  update-initramfs -c -k all
EOCHROOT
}

Docker-install(){
  echo "------------> Install Docker <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  ${APT} install ca-certificates
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  ${APT} update
  sync
  sleep 2
  ${APT} install -y docker-ce
EOCHROOT
}

ZBM_install() {
  # Install and configure ZFSBootMenu
  # Set ZFSBootMenu properties on datasets
  # Create a vfat filesystem
  # Create an fstab entry and mount
  echo "------------> Installing ZFSBootMenu <------------"
  cat <<EOF >>${MOUNTPOINT}/etc/fstab
$(blkid | grep "${USB}${BOOT_PART}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
EOF

  mkdir -p "${MOUNTPOINT}"/boot/efi

  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  zfs set org.zfsbootmenu:commandline="quiet loglevel=4 splash" "${POOLNAME}"/ROOT
  # if it still does not boot look at this
  zfs set org.zfsbootmenu:keysource="${POOLNAME}"/ROOT/" "${POOLNAME}"
  echo "$USB - "$USB"1 - ${USB}${BOOT_PART}"
  mkfs.vfat -v -F32 "$USB"$BOOT_PART # the EFI partition must be formatted as FAT32
  sync
  sleep 2
EOCHROOT

  # Install ZBM and configure EFI boot entries
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  mount /boot/efi
  mkdir -p /boot/efi/EFI/ZBM
  curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
  cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars
EOCHROOT
}

# Create boot entry with efibootmgr
EFI_install() {
  echo "------------> Installing efibootmgr <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
${APT} install -y efibootmgr
efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

efibootmgr -c -d "$USB" -p "$BOOT_PART" \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI'

sync
sleep 1
EOCHROOT
}

# Create system groups and network setup
networking() {
  echo "------------> Setup groups and networks <----------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  # Enable systemd-networkd for network management
  systemctl enable systemd-networkd
  # Configure Ethernet (DHCP)
  echo "[Match]
Name=eno2

[Network]
DHCP=yes" >/etc/systemd/network/20-wired.network

  # Reload systemd-networkd to apply network configurations
EOCHROOT
}

# Create user
create_user() {
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  adduser --disabled-password --gecos "" ${USERNAME}
  cp -a /etc/skel/. /home/${USERNAME}
  chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}
  usermod -a -G adm,cdrom,dip,docker,sudo ${USERNAME}
  echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/${USERNAME}
  chown root:root /etc/sudoers.d/${USERNAME}
  chmod 400 /etc/sudoers.d/${USERNAME}
  echo -e "${USERNAME}:$PASSWORD" | chpasswd
EOCHROOT
}

# Install distro bundle
install_ubuntu() {
  echo "------------> Installing ${DISTRO} bundle <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
    ${APT} update
    ${APT} dist-upgrade -y
    ${APT} install -y ubuntu-server
EOCHROOT
}

# Disable log gzipping as we already use compresion at filesystem level
uncompress_logs() {
  echo "------------> Uncompress logs <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "${file}" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "${file}"
    fi
  done
EOCHROOT
}

# Create user
Import-sshkey() {
  echo "------------> Import sshkey <------------"
    chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT

    # Ensure the root .ssh directory exists with the correct permissions
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # Ensure the authorized_keys file exists with the correct permissions
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Append the SSH public key to the root's authorized_keys file
    echo $SSH_PUBLIC_KEY >> /root/.ssh/authorized_keys
    echo "Added specified SSH public key to root's authorized_keys"

    echo "SSH key addition completed for root user."

    # Modify /etc/ssh/sshd_config to allow root login
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
    systemctl restart sshd

EOCHROOT
}

# Function to ask for confirmation to continue
confirm_continue() {
    while true; do
        read -p "Did you set the right USB drive to this script? (yes/no) " yn
        case $yn in
            [Yy]* ) break;; # If input starts with 'y' or 'Y', exit loop and continue script
            [Nn]* ) echo "Exiting script."; exit;; # If input starts with 'n' or 'N', exit script
            * ) echo "Please answer yes or no.";; # For any other input, ask again
        esac
    done
}

#Umount target and final cleanup
cleanup() {
  echo "------------> Final cleanup <------------"
  umount -n -R "${MOUNTPOINT}"
  sync
  sleep 5
  umount -n -R "${MOUNTPOINT}" >/dev/null 2>&1

  zpool export "${POOLNAME}"
}

confirm_continue
initialize
disk_prepare
zfs_pool_create
ubuntu_debootstrap
ZBM_install
EFI_install
networking
#create_user
install_ubuntu
uncompress_logs
Docker-install
Import-sshkey
cleanup

if [[ ${REBOOT} =~ "true" ]]; then
  reboot
fi
