# virt-install --virt-type kvm --os-variant rhel10.0 --arch s390x --name rhel10.0 --memory 8192 --location rhel-10.0-s390x-dvd.iso --disk path=./disk.qcow2,format=qcow2,bus=scsi,size=7 --initrd-inject=rhel10-s390x-dm-root.ks --nographics --extra-args "console=ttysclp0 inst.ks=file:/rhel10-s390x-dm-root.ks" --transient

text
repo --name="AppStream" --baseurl=file:///run/install/sources/mount-0000-cdrom/AppStream

%addon com_redhat_kdump --enable --reserve-mb='auto'
%end

keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8

network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled

cdrom

rootpw --allow-ssh redhat123

selinux --enforcing

services --enabled="sshd,NetworkManager,nm-cloud-setup.service,nm-cloud-setup.timer,cloud-init,cloud-init-local,cloud-config,cloud-final"

timezone Etc/UTC --utc

skipx

poweroff

%packages
@^minimal-environment
openssh-server
kernel
kernel-modules
kernel-modules-extra
redhat-release

-*gpu-firmware*
-linux-firmware*
-iwl*

cloud-init
cloud-utils-growpart
NetworkManager-cloud-setup

cryptsetup
s390utils-base

python3-dnf-plugin-versionlock

tpm2-tools
afterburn
e2fsprogs

%end

firstboot --disable

ignoredisk --only-use=sda
clearpart --all --initlabel --drives=sda

part / --fstype="ext4" --ondisk=sda --grow

%post --erroronfail

# Linux root (s390x GUID: 69A113B8-15A0-4E37-A5B6-3E10A03E0343)
sfdisk --part-type /dev/sda 1 69A113B8-15A0-4E37-A5B6-3E10A03E0343

# Initialize zipl bootloader
if [ -x /sbin/zipl ]; then
    /sbin/zipl || true
fi

fstrim -v / ||:

%end
