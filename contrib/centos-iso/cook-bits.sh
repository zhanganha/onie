#!/bin/bash

#
#  Copyright (C) 2017 Rajendra Dendukuri <rajendra.dendukuri@broadcom.com>
#
#  SPDX-License-Identifier:     GPL-2.0
#

# Make an ONIE installer using CentOS 7 chroot environment
#
# inputs: cento7 chroot package
# output: ONIE compatible OS installer image
#
# Comments: This script expects that yumbootsstrap is installed on
#           on the Linux host where it is executed.

#!/bin/sh

set -e

IN=./input
OUT=./output
rm -rf $OUT
mkdir -p $OUT

WORKDIR=./work
EXTRACTDIR="$WORKDIR/extract"
INSTALLDIR="$WORKDIR/installer"

# Create a centos-7 chroot package if not done already
DISTR0_VER=centos-7
CHROOT_PKG="${DISTR0_VER}-chroot.tar.bz2"
[ ! -r ${IN}/${CHROOT_PKG} ] && {
   CHROOT_PATH="${WORKDIR}/${DISTR0_VER}-chroot"
   mkdir -p ${CHROOT_PATH}
   which yumbootstrap  > /dev/null 2>&1
   if [ $? -ne 0 ]; then
      echo "Error: yumbootstrap tool not found. Please install yumbootstrap."
      exit 1;
   fi
   PKG_LIST=openssh-server,grub2
   /usr/sbin/yumbootstrap --include=${PKG_LIST} --verbose --group=Core ${DISTR0_VER} ${CHROOT_PATH}
   cd ${CHROOT_PATH}
   ln -sf boot/vmlinuz-$(ls -1 lib/modules | tail -1) vmlinuz
   ln -sf boot/initramfs-$(ls -1 lib/modules | tail -1).img initrd.img
   cd -
   mkdir -p ${IN}
   tar -cjf ${IN}/${CHROOT_PKG} -C ${CHROOT_PATH} .
}

output_file="${OUT}/${DISTR0_VER}-ONIE.bin"

echo -n "Creating $output_file: ."

# prepare workspace
[ -d $EXTRACTDIR ] && chmod +w -R $EXTRACTDIR
rm -rf $WORKDIR
mkdir -p $EXTRACTDIR
mkdir -p $INSTALLDIR

# Copy distro package
cp -f ${IN}/${CHROOT_PKG} $INSTALLDIR

# Create custom install.sh script
cp install.sh $INSTALLDIR/install.sh
chmod +x $INSTALLDIR/install.sh

# Create o/s setup script
touch $INSTALLDIR/distro-setup.sh
chmod +x $INSTALLDIR/distro-setup.sh

(cat <<EOF
#!/bin/sh

# Create default user onie, with password onie
echo "Setting user onie password as onie"
useradd -s /bin/bash -m -k /dev/null onie
echo onie | passwd onie --stdin
echo "onie    ALL=(ALL)       ALL" >> /etc/sudoers
echo onie | passwd --stdin

# Setup o/s mount points
(cat <<EOF2
tmpfs                   /tmp                    tmpfs   defaults        0 0
tmpfs                   /dev/shm                tmpfs   defaults        0 0
devpts                  /dev/pts                devpts  gid=5,mode=620  0 0
sysfs                   /sys                    sysfs   defaults        0 0
proc                    /proc                   proc    defaults        0 0
\${1}               /                       ext4    defaults        1 1
EOF2
) > /etc/fstab

# Configure default hostname
echo "HOSTNAME=localhost" > /etc/sysconfig/network

# Disable selinux
sed -ie "s/SELINUX=/SELINUX=disabled/g" /etc/selinux/config

# Customizations

exit 0
EOF
) > $INSTALLDIR/distro-setup.sh


echo -n "."

# Repackage $INSTALLDIR into a self-extracting installer image
sharch="$WORKDIR/sharch.tar"
tar -C $WORKDIR -cf $sharch installer || {
    echo "Error: Problems creating $sharch archive"
    exit 1
}

[ -f "$sharch" ] || {
    echo "Error: $sharch not found"
    exit 1
}
echo -n "."

sha1=$(cat $sharch | sha1sum | awk '{print $1}')
echo -n "."

cp sharch_body.sh $output_file || {
    echo "Error: Problems copying sharch_body.sh"
    exit 1
}

# Replace variables in the sharch template
sed -i -e "s/%%IMAGE_SHA1%%/$sha1/" $output_file
echo -n "."
cat $sharch >> $output_file
rm -rf $tmp_dir
echo " Done."
