#!/bin/bash
# Spike #3: switch the running lab VM to a systemd initramfs (sd-encrypt) and rebuild the UKI. Not product code.
# Keeps the passphrase as the only key and leaves the Limine command line (cryptdevice=) as Omarchy wrote it.
source "$(dirname "$0")/../lib.sh"
lab_ssh 'cat > /tmp/zz-monarchy-encryption.conf' < "$VM/spike/zz-monarchy-encryption.conf"
lab_ssh "echo $LAB_PASSWORD | sudo -S -p '' bash -euc '
  install -m644 /tmp/zz-monarchy-encryption.conf /etc/mkinitcpio.conf.d/zz-monarchy-encryption.conf
  uuid=\$(cryptsetup luksUUID /dev/vda2)
  grep -q \"^root \" /etc/crypttab || printf \"root  UUID=%s  none  luks,x-initrd.attach\n\" \"\$uuid\" >> /etc/crypttab
  limine-mkinitcpio 2>&1 | grep -E \"ERROR|deprecated|Unified kernel image generation\"
'"
