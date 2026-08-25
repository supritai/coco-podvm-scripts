# s390x CoCo PodVM Image Build — Notes & Changes

**Branch:** `support-s390x-podvm-image`  
**Host:** RHEL 10.2 s390x (`b151-a06`)  
**Output:** `/home/linuxuser/suprit/new_build/output/disk.qcow2`  
**Output size:** 9.93 GiB virtual, 1.42 GiB actual (qcow2)  
**Commit:** `138255e`

---

## Build Flow

```
Step 1 — virt-install
  RHEL 10.2 s390x ISO + kickstart → base RHEL qcow2 (7 GiB, ~915 MiB actual)

Step 2 — example_run.sh (podman container pipeline)
  2a. Dockerfile builds coco-podvm container image (UBI9 + guestfs-tools + s390utils-base)
  2b. virt-customize → script-disk-mods.sh  (kernel update, s390utils)
  2c. virt-customize → podvm_maker.sh       (podvm binaries, luks, services)
  2d. verity.sh                             (dm-verity + BLS + zipl bootmap)

Output: dm-verity protected s390x CoCo podvm qcow2
```

---

## Commands Used

### Step 1 — Create base disk with virt-install

```bash
sudo virt-install \
  --virt-type kvm \
  --cpu host-model \
  --os-variant rhel10.2 \
  --arch s390x \
  --name podvm-s390x-build \
  --memory 8192 \
  --location /home/linuxuser/RHEL-10.2-updates-20260511.1-s390x-dvd1.iso \
  --disk path=/home/linuxuser/suprit/new_build/output/disk.qcow2,format=qcow2,bus=scsi,size=7 \
  --initrd-inject=helpers/rhel10-s390x-dm-root.ks \
  --nographics \
  --extra-args 'console=ttysclp0 inst.ks=file:/rhel10-s390x-dm-root.ks inst.cmdline inst.text' \
  --transient
```

> `inst.cmdline` and `inst.text` are required on s390x — without them Anaconda
> stops and waits for interactive input (VNC/terminal) and never proceeds.

### Step 2 — Run the coco pipeline

```bash
cd /home/linuxuser/suprit/new_build/coco-podvm-scripts

export ACTIVATION_KEY=<your-activation-key>
export ORG_ID=<your-org-id>

sudo chown linuxuser:linuxuser /home/linuxuser/suprit/new_build/output/disk.qcow2
sudo -E bash example_run.sh /home/linuxuser/suprit/new_build/output/disk.qcow2
```

---

## Bugs Found and Fixed

### 1. `helpers/rhel10-s390x-dm-root.ks`

| # | Issue | Fix |
|---|---|---|
| 1 | `s390utils-zipl` does not exist as a separate package on RHEL 10 — `zipl` is included in `s390utils-base`. Anaconda failed with *missing packages* error. | Removed `s390utils-zipl` from `%packages` |
| 2 | `clearpart --none --initlabel` is unreliable on a blank qcow2 — may not write a GPT before the `%post` `sfdisk --part-type` call which requires a valid GPT. | Changed to `clearpart --all --initlabel --drives=sda` |
| 3 | `part / --maxsize=0` is invalid kickstart syntax (`0` is not a valid max size). | Removed `--maxsize=0`; `--grow` alone is correct |
| 4 | Missing firmware exclusions (`*gpu-firmware*`, `linux-firmware*`, `iwl*`) — x86 ks had them to slim the image. | Added exclusions to `%packages` |
| 5 | Missing `tpm2-tools` — needed by `gen-issue` at boot for PCR readings via `tpm2_pcrread`. | Added `tpm2-tools` to `%packages` |

### 2. `scripts/verity/verity.sh`

| # | Issue | Fix |
|---|---|---|
| 1 | **Critical** — `apply_dmverity()` wrote `Type=root-verity` / `Type=root` (generic) into `systemd-repart` conf files regardless of arch. On s390x the jq query filtered for `root-s390x-verity` so roothash was always empty → build fails. | Use arch-specific types: `root-s390x-verity` / `root-s390x` on s390x, `root-x86-64-verity` / `root-x86-64` on x86_64 |
| 2 | `current_size` and `verity_max_space` were only computed inside `resize_disk()`. If `RESIZE_DISK != yes`, `apply_dmverity()` used empty variables → `systemd-repart` failed. | Compute both unconditionally before the resize check |
| 3 | **Critical** — After verity, s390x path just printed the roothash and exited. The bootloader was never updated → image unbootable with verity. | Mount root partition, patch BLS entry `options=` line with `roothash=$RH systemd.volatile=overlay`, re-run `zipl` via chroot |
| 4 | RHEL 10 uses BLS (Boot Loader Spec) entries in `/boot/loader/entries/*.conf`, not the old `parameters=` style in `zipl.conf`. The original `sed` pattern would never match. | Patch `options` line in BLS `.conf` files; fall back to `zipl.conf` only if no BLS entries found |
| 5 | `zipl` called without `--targettype SCSI` inside chroot on NBD device → `Error: Could not get disk geometry` (NBD doesn't support `HDIO_GETGEO` ioctl). | Added `--targettype SCSI` to zipl call — skips geometry detection |
| 6 | `handle_ctrlc` trap didn't unmount s390x chroot bind mounts (`mnt/dev`, `mnt/proc`, `mnt/sys`) before the root mount, leaving the NBD device busy on error. | Unmount bind mounts in correct order before root in trap |
| 7 | Dead `$root_mounted` variable referenced in trap — never set anywhere. | Removed the dead check |

### 3. `scripts/coco/podvm/podvm_maker.sh`

| # | Issue | Fix |
|---|---|---|
| 1 | `afterburn-checkin.service` heredoc was missing the `[Install]` section — unit file was non-standard. | Added `[Install] WantedBy=multi-user.target` after the conditional `ExecStart=` append |
| 2 | `dnf remove -y cloud-init WALinuxAgent` fails on s390x — `WALinuxAgent` is not installed. | Changed to `dnf remove -y cloud-init WALinuxAgent \|\| dnf remove -y cloud-init` |

### 4. `scripts/coco/podvm/script-disk-mods.sh`

| # | Issue | Fix |
|---|---|---|
| 1 | `s390utils-zipl` doesn't exist on RHEL 10 — `dnf install` would fail. | Removed `s390utils-zipl` from the s390x `dnf install` line |
| 2 | Missing `dnf clean all` on s390x path — left dnf cache bloating the image. | Added `dnf clean all` after s390x kernel install |

### 5. `scripts/create-verity-podvm.sh`

| # | Issue | Fix |
|---|---|---|
| 1 | Help text listed `sbsigntools` and `az` as required packages (x86-only / unused). `ROOT_PARTITION_UUID` description said "x86_64 part type". | Updated comments to be arch-aware |

---

## Key s390x Architecture Differences vs x86_64

| Concern | x86_64 | s390x |
|---|---|---|
| Bootloader | UEFI + UKI addon (`.efi`) | zipl + BLS entries in `/boot/loader/entries/` |
| Serial console | `ttyS0` | `ttysclp0` |
| Root partition GUID | `4f68bce3-e8cd-4db1-96e7-fbcaf984b709` | `69a113b8-15a0-4e37-a5b6-3e10a03e0343` |
| systemd-repart type | `root-x86-64` / `root-x86-64-verity` | `root-s390x` / `root-s390x-verity` |
| Verity roothash delivery | UKI addon `.efi` in ESP | BLS `options=` line + zipl bootmap |
| Secure Boot signing | `sbsigntools` (shim) | Not applicable |
| Disk partition layout | EFI (p1) + root (p2) | root only (p1) |
| Packages excluded | — | `systemd-ukify`, `sbsigntools`, NVIDIA drivers |
| Packages required | — | `s390utils-base` (includes zipl) |
| virt-install extra args | `--boot uefi` | `inst.cmdline inst.text` (no interactive prompts) |

---

## Verification

After the pipeline completes, verify the disk with:

```bash
# Check partition layout and GUID
sudo modprobe nbd
sudo qemu-nbd -r -c /dev/nbd1 -f qcow2 /path/to/disk.qcow2
sleep 2
sudo lsblk -o NAME,PARTTYPE,SIZE /dev/nbd1
# Expected: nbd1p1 (root), nbd1p2 (LUKS scratch), nbd1p3 (verity hash)

# Check BLS entry has roothash
sudo mount /dev/nbd1p1 /tmp/mnt
sudo grep "roothash" /tmp/mnt/boot/loader/entries/*.conf | grep -v rescue
sudo grep "roothash" /tmp/mnt/boot/loader/entries/*.conf | grep -v rescue | grep "systemd.volatile=overlay"
sudo umount /tmp/mnt
sudo qemu-nbd --disconnect /dev/nbd1
```
