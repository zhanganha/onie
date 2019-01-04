#!/bin/sh


#  SPDX-License-Identifier:     GPL-2.0

set -e

cd $(dirname $0)


# with "OS" or "DIAG".
inspur_type="DIAG"

inspur_volume_label="INSPUR-SUPERIOR-${inspur_type}"

# init blk_dev
onie_dev=$(blkid | grep ONIE-BOOT | head -n 1 | awk '{print $1}' |  sed -e 's/:.*$//')
blk_dev=$(echo $onie_dev | sed -e 's/[1-9][0-9]*$//' | sed -e 's/\([0-9]\)\(p\)/\1/')
# Note: ONIE has no mount setting for / with device node, so below will be empty string
cur_part=$(cat /proc/mounts | awk "{ if(\$2==\"/\") print \$1 }" | grep $blk_dev || true)

[ -b "$blk_dev" ] || {
    echo "Error: Unable to determine block device of ONIE install"
    exit 1
}

onie_root_dir=/mnt/onie-boot/onie
kernel_args="console=tty0 console=ttyS0,115200n8"
grub_serial_command="serial --port=0x3f8 --speed=115200 --word=8 --parity=no --stop=1"

# auto-detect whether BIOS or UEFI
if [ -d "/sys/firmware/efi/efivars" ] ; then
    firmware="uefi"
else
    firmware="bios"
fi

# determine ONIE partition type
onie_partition_type=$(onie-sysinfo -t)
# inspur partition size in MB
inspur_part_size=4096
if [ "$firmware" = "uefi" ] ; then
    create_inspur_partition="create_inspur_uefi_partition"
elif [ "$onie_partition_type" = "gpt" ] ; then
    create_inspur_partition="create_inspur_gpt_partition"
elif [ "$onie_partition_type" = "msdos" ] ; then
    create_inspur_partition="create_inspur_msdos_partition"
else
    echo "ERROR: Unsupported partition type: $onie_partition_type"
    exit 1
fi

# Creates a new partition for the inspur OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $inspur_part
inspur_part=
create_inspur_gpt_partition()
{
    blk_dev="$1"

    # See if inspur partition already exists
    inspur_part=$(sgdisk -p $blk_dev | grep "$inspur_volume_label" | awk '{print $1}')
    if [ -n "$inspur_part" ] ; then
        # delete existing partition
        sgdisk -d $inspur_part $blk_dev || {
            echo "Error: Unable to delete partition $inspur_part on $blk_dev"
            exit 1
        }
        partprobe
    fi

    # Find next available partition
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    inspur_part=$(( $last_part + 1 ))
    # check if we have an mmcblk device
    blk_suffix=
    echo ${blk_dev} | grep -q mmcblk && blk_suffix="p"
    # check if we have an nvme device
    echo ${blk_dev} | grep -q nvme && blk_suffix="p"

    # Create new partition
    echo "Creating new inspur partition ${blk_dev}$blk_suffix$inspur_part ..."

    if [ "$inspur_type" = "DIAG" ] ; then
        # set the GPT 'system partition' attribute bit for the DIAG
        # partition.
        attr_bitmask="0x1"
    else
        attr_bitmask="0x0"
    fi
    sgdisk --new=${inspur_part}::+${inspur_part_size}MB \
        --attributes=${inspur_part}:=:$attr_bitmask \
        --change-name=${inspur_part}:$inspur_volume_label $blk_dev || {
        echo "Error: Unable to create partition $inspur_part on $blk_dev"
        exit 1
    }
    partprobe
}

create_inspur_msdos_partition()
{
    blk_dev="$1"

    # See if inspur partition already exists -- look for the filesystem
    # label.
    part_info="$(blkid | grep $inspur_volume_label | awk -F: '{print $1}')"
    if [ -n "$part_info" ] ; then
        # delete existing partition
        inspur_part="$(echo -n $part_info | sed -e s#${blk_dev}##)"
        parted -s $blk_dev rm $inspur_part || {
            echo "Error: Unable to delete partition $inspur_part on $blk_dev"
            exit 1
        }
        partprobe
    fi

    # Find next available partition
    last_part_info="$(parted -s -m $blk_dev unit s print | tail -n 1)"
    last_part_num="$(echo -n $last_part_info | awk -F: '{print $1}')"
    last_part_end="$(echo -n $last_part_info | awk -F: '{print $3}')"
    # Remove trailing 's'
    last_part_end=${last_part_end%s}
    inspur_part=$(( $last_part_num + 1 ))
    inspur_part_start=$(( $last_part_end + 1 ))
    # sectors_per_mb = (1024 * 1024) / 512 = 2048
    sectors_per_mb=2048
    inspur_part_end=$(( $inspur_part_start + ( $inspur_part_size * $sectors_per_mb ) - 1 ))

    # Create new partition
    echo "Creating new inspur partition ${blk_dev}$inspur_part ..."
    parted -s --align optimal $blk_dev unit s \
      mkpart primary $inspur_part_start $inspur_part_end set $inspur_part boot on || {
        echo "ERROR: Problems creating inspur msdos partition $inspur_part on: $blk_dev"
        exit 1
    }
    partprobe

}

# For UEFI systems, create a new partition for the inspur OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $inspur_part
create_inspur_uefi_partition()
{
    create_inspur_gpt_partition "$1"

    # erase any related EFI BootOrder variables from NVRAM.
    for b in $(efibootmgr | grep "$inspur_volume_label" | awk '{ print $1 }') ; do
        local num=${b#Boot}
        # Remove trailing '*'
        num=${num%\*}
        efibootmgr -b $num -B > /dev/null 2>&1
    done
}

# Install legacy BIOS GRUB for inspur OS
inspur_install_grub()
{
    local inspur_mnt="$1"
    local blk_dev="$2"

    # keep grub loading ONIE page after installing diag.
    # So that it is not necessary to set "ONIE" as default boot
    # mode in diag's grub.cfg.
    if [ "$inspur_type" = "DIAG" ] ; then
        # Install GRUB in the partition also.  This allows for
        # chainloading the DIAG image from another OS.
        #
        # We are installing GRUB in a partition, as opposed to the
        # MBR.  With this method block lists are used to refer to the
        # the core.img file.  The sector locations of core.img may
        # change whenever the file system in the partition is being
        # altered (files copied, deleted etc.). For more info, see
        # https://bugzilla.redhat.com/show_bug.cgi?id=728742 and
        # https://bugzilla.redhat.com/show_bug.cgi?id=730915.
        #
        # The workaround for this is to set the immutable flag on
        # /boot/grub/i386-pc/core.img using the chattr command so that
        # the sector locations of the core.img file in the disk is not
        # altered. The immutable flag on /boot/grub/i386-pc/core.img
        # needs to be set only if GRUB is installed to a partition
        # boot sector or a partitionless disk, not in case of
        # installation to MBR.
        
        core_img="$demo_mnt/grub/i386-pc/core.img"
        # remove immutable flag if file exists during the update.
        [ -f "$core_img" ] && chattr -i $core_img

        grub-install  --force --boot-directory="$inspur_mnt" \
            --recheck "$inspur_dev"  || {
            echo "ERROR: grub-install failed on: $inspur_dev"
            cat $grub_install_log && rm -f $grub_install_log
            exit 1
        }

        # restore immutable flag on the core.img file as discussed
        # above.
        [ -f "$core_img" ] && chattr +i $core_img

    else
        # Pretend we are a major distro and install GRUB into the MBR of
        # $blk_dev.
        grub-install --boot-directory="$inspur_mnt" --recheck "$blk_dev" || {
            echo "ERROR: grub-install failed on: $blk_dev"
            exit 1
        }

    fi

}

# Install UEFI BIOS GRUB for inspur OS
inspur_install_uefi_grub()
{
    local inspur_mnt="$1"
    local blk_dev="$2"

    # make sure /boot/efi is mounted
    if ! mount | grep -q "/boot/efi"; then
        mount /boot/efi
    fi

    # Look for the EFI system partition UUID on the same block device as
    # the ONIE-BOOT partition.
    local uefi_part=0
    for p in $(seq 8) ; do
        if sgdisk -i $p $blk_dev | grep -q C12A7328-F81F-11D2-BA4B-00A0C93EC93B ; then
            uefi_part=$p
            break
        fi
    done

    [ $uefi_part -eq 0 ] && {
        echo "ERROR: Unable to determine UEFI system partition"
        exit 1
    }

    
        # Regular GRUB install
        
    grub-install \
        --no-nvram \
        --bootloader-id="$inspur_volume_label" \
        --efi-directory="/boot/efi" \
        --boot-directory="$inspur_mnt" \
        --recheck \
        "$blk_dev"  || {
        echo "ERROR: grub-install failed on: $blk_dev"
        exit 1
    }
    
    # Configure EFI NVRAM Boot variables.  --create also sets the
    # new boot number as active.
    efibootmgr --quiet --create \
        --label "$inspur_volume_label" \
        --disk $blk_dev --part $uefi_part \
        --loader "/EFI/$inspur_volume_label/grubx64.efi" || {
        echo "ERROR: efibootmgr failed to create new boot variable on: $blk_dev"
        exit 1
    }

    # keep grub loading ONIE page after installing diag.
    # So that it is not necessary to set "ONIE" as default boot
    # mode in diag's grub.cfg.
    if [ "$inspur_type" = "DIAG" ] ; then
        boot_num=$(efibootmgr -v | grep "ONIE: " | grep ')/File(' | \
            tail -n 1 | awk '{ print $1 }' | sed -e 's/Boot//' -e 's/\*//')
        boot_order=$(efibootmgr | grep BootOrder: | awk '{ print $2 }' | \
            sed -e s/,$boot_num// -e s/$boot_num,// -e s/$boot_num//)
        if [ -n "$boot_order" ] ; then
            boot_order="${boot_num},$boot_order"
        else
            boot_order="$boot_num"
        fi
        efibootmgr --quiet --bootorder "$boot_order" || {
            echo "ERROR: efibootmgr failed to set new boot order"
            return 1
        }

    fi

}

eval $create_inspur_partition $blk_dev
inspur_dev=$(echo $blk_dev | sed -e 's/\(mmcblk[0-9]\)/\1p/')$inspur_part
echo $blk_dev | grep -q nvme && {
    inspur_dev=$(echo $blk_dev | sed -e 's/\(nvme[0-9]n[0-9]\)/\1p/')$inspur_part
}
partprobe

# Create filesystem on inspur partition with a label
mkfs.ext4 -F -L $inspur_volume_label $inspur_dev || {
    echo "Error: Unable to create file system on $inspur_dev"
    exit 1
}

# Mount inspur filesystem
inspur_mnt=$(mktemp -d) || {
    echo "Error: Unable to create inspur file system mount point"
    exit 1
}
mount -t ext4 -o defaults,rw $inspur_dev $inspur_mnt || {
    echo "Error: Unable to mount $inspur_dev on $inspur_mnt"
    exit 1
}

cp -f distro-setup.sh ${inspur_mnt}
echo "Extract chroot environment ..."
DISTR0_VER=centos-7
CHROOT_PKG="${DISTR0_VER}-chroot.tar.bz2"
tar -xf ${CHROOT_PKG} -C ${inspur_mnt}
[ -e ${inspur_mnt}/dev/pts ] && {
    mount -o bind /dev/pts ${inspur_mnt}/dev/pts
}
mount -t proc proc ${inspur_mnt}/proc
mount -t sysfs sys ${inspur_mnt}/sys
cp -a ${blk_dev} ${inspur_mnt}/${blk_dev}
echo "Setting up distro .."
chroot ${inspur_mnt} /distro-setup.sh ${inspur_dev}
[ -e ${inspur_mnt}/dev/pts ] && {
   umount ${inspur_mnt}/dev/pts
}
umount ${inspur_mnt}/proc
umount ${inspur_mnt}/sys





# If ONIE supports boot command feeding,
# adds inspur DIAG bootcmd to ONIE.
if grep -q 'ONIE_SUPPORT_BOOTCMD_FEEDING' $onie_root_dir/grub.d/50_onie_grub &&
    [ "$inspur_type" = "DIAG" ] ; then
    cat <<EOF > $onie_root_dir/grub/diag-bootcmd.cfg
    diag_menu="inspur $inspur_type"
    function diag_bootcmd {
      search --no-floppy --label --set=root $inspur_volume_label
      echo    'Loading ONIE inspur $inspur_type kernel ...'
      linux   /vmlinuz ${kernel_args} root=${blk_dev}${inspur_part}
      echo    'Loading ONIE inspur $inspur_type initial ramdisk ...'
      initrd  /initrd.img
      boot
    }
    EOF

    # Update ONIE grub configuration -- use the grub fragment provided by the
    # ONIE distribution.
    $onie_root_dir/grub.d/50_onie_grub > /dev/null

else
    # Install a separate GRUB for inspur DIAG or NOS
    # that supports GRUB chainload function.

    if [ "$firmware" = "uefi" ] ; then
        inspur_install_uefi_grub "$inspur_mnt" "$blk_dev"
    else
        inspur_install_grub "$inspur_mnt" "$blk_dev"
    fi

    # Create a minimal grub.cfg that allows for:
    #   - configure the serial console
    #   - allows for grub-reboot to work
    #   - a menu entry for the inspur OS
    #   - menu entries for ONIE
    grub_cfg=$(mktemp)

    # Add common configuration, like the timeout and serial console.
    cat <<EOF > $grub_cfg
        $grub_serial_command
        terminal_input serial
        terminal_output serial

        set timeout=5

    EOF

    # Add any platform specific kernel command line arguments.  This sets
    # the $ONIE_EXTRA_CMDLINE_LINUX variable referenced above in
    # $GRUB_CMDLINE_LINUX.
    cat $onie_root_dir/grub/grub-extra.cfg >> $grub_cfg

    # Add the logic to support grub-reboot
    cat <<EOF >> $grub_cfg
    if [ -s \$prefix/grubenv ]; then
       load_env
    fi
    if [ "\${next_entry}" ] ; then
      set default="\${next_entry}"
      set next_entry=
      save_env next_entry
    fi

    EOF

    # Add a menu entry for the inspur OS
    inspur_grub_entry="inspur $inspur_type"
    cat <<EOF >> $grub_cfg
      menuentry '${inspur_volume_label}' {
        search --no-floppy --label --set=root $inspur_volume_label
        echo    'Loading ONIE inspur $inspur_type kernel ...'
        linux   /vmlinuz ${kernel_args} root=${blk_dev}${inspur_part}
        echo    'Loading ONIE inspur $inspur_type initial ramdisk ...'
        initrd  /initrd.img
     }
    EOF

    # Add menu entries for ONIE -- use the grub fragment provided by the
    # ONIE distribution.
    $onie_root_dir/grub.d/50_onie_grub >> $grub_cfg

    cp -f ${grub_cfg} ${inspur_mnt}/boot/grub/grub.cfg
    cat ${grub_cfg} >> ${inspur_mnt}/etc/grub.d/40_onie_grub
   
fi

# clean up
umount $inspur_mnt || {
    echo "Error: Problems umounting $inspur_mnt"
}

cd /

if [ "$inspur_type" = "OS" ] ; then
    # Set NOS mode if available -- skip this for diag installers
    if [ -x /bin/onie-nos-mode ] ; then
        /bin/onie-nos-mode -s
    fi
fi
