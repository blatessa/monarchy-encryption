---
title: "Spike: systemd initramfs (sd-encrypt) on Omarchy"
labels: P0, needs-lab
---
**Goal:** know whether Omarchy boots cleanly with `systemd` + `sd-encrypt` hooks, which TPM unlock requires, and what breaks.

**Context:** Omarchy uses busybox hooks with `cryptdevice=` (see `docs/research.md`). The switch means a drop-in that sorts after `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, an `/etc/crypttab.initramfs` (a guide reports boot hangs without it), and dropping `cryptdevice=` from the Limine command line. Unknown: `btrfs-overlayfs` (snapshot boot), Plymouth's themed prompt, keymap via `sd-vconsole`, hibernate `resume=`, and Omarchy migrations that rewrite `omarchy_hooks.conf`. Clevis (keeps busybox hooks) is the fallback option.

**Done when:** in the lab, with a passphrase still the only key, the VM boots, shows the themed prompt, boots a snapshot entry, resumes from hibernate, and survives a kernel update and `omarchy-refresh-limine`. Every finding is in `docs/dev/findings.md`, and a recommendation (sd-encrypt or clevis) is written in `docs/dev/architecture.md`. Spike only: no CLI code.

**Depends on:** Lab.
