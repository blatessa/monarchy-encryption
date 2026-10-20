# `status` output

`monarchy-encryption status` tells you whether a laptop's disk is protected the way `setup` leaves it, and if not,
what's missing. It only looks: it never changes anything, and it needs no passphrase or recovery key.

Run it as root (`sudo`) for the full answer. Without root it can't read the disk's keys, the TPM's record of the boot
files or the boot menu's protection, and those show as unknown.

## For a person

```text
$ sudo monarchy-encryption status
Protected:              no: disk.tpm_unlock
Disk encrypted:         yes
  ready for TPM unlock: yes
  first-boot setup:     done
  TPM unlocks it:       no (enrolled, but it no longer opens the disk: run setup with the recovery key)
  opens by itself once: no
  recovery key:         yes
  passphrase:           no
TPM policy:             yes
  covers boot files:    yes
Boot menu:
  entries locked:       yes
  menu protected:       yes
  fallback protected:   yes
```

## For an MDM or a script: `status --json`

One JSON object on one line. Check `protected` first. When it's `false`, `missing` names what to fix.

```json
{
  "schema": 2,
  "protected": true,
  "missing": [],
  "disk": {
    "encrypted": true, "systemd_initramfs": true, "provisioning_pending": false,
    "tpm_unlock": true, "tpm_enrolled": true, "one_time_unlock": false,
    "recovery_key": true, "passphrase": false
  },
  "boot_menu": { "editor_locked": true, "config_protected": true, "fallback_protected": true },
  "tpm_policy": { "exists": true, "pcrs": [4, 11], "current": true }
}
```

Every value is `true`, `false`, or `null`. **`null` means unknown, never "no"**: usually because `status` didn't run
as root.

### The answer

| Field | Meaning |
|---|---|
| `schema` | The version of this format. It changes only when a field changes meaning or goes away; new fields can be added without changing it. Version 2 replaced `secure_boot` and `disk.tpm_pcrs` with `tpm_policy`. |
| `protected` | `true` when everything below that `setup` takes care of is as it should be. `false` when anything is wrong (even if other things are unknown). `null` when nothing is wrong but something couldn't be checked. |
| `missing` | The fields that keep `protected` from being `true`, written as `section.field`, for example `"disk.tpm_unlock"`. Unknown fields aren't listed. `disk.no_passphrase` is listed when the disk still has a passphrase, `disk.no_one_time_unlock` until the restart after `setup`, `disk.no_provisioning_pending` while Omarchy's first-boot setup is pending. |

### `disk`

| Field | `true` means | When it's `false` |
|---|---|---|
| `encrypted` | The system disk is encrypted. | `setup` can't help: reinstall with encryption. |
| `systemd_initramfs` | The laptop starts with the boot environment that can use the TPM. | Run `setup`. |
| `provisioning_pending` | Omarchy's first-boot setup hasn't run yet (a laptop installed for a later owner, or after a factory reset). Shown without root too. | `false` is the goal. While it's `true`, `setup` refuses: finish first-boot setup first. |
| `tpm_unlock` | The TPM opens the disk **right now**, so the laptop will start without asking for anything. | If `tpm_enrolled` is `true`, the TPM no longer holds what it needs (it was cleared, or the laptop's mainboard was replaced): the laptop asks for the recovery key at start. Run `setup` with the recovery key. Otherwise run `setup`. |
| `tpm_enrolled` | The TPM has been set up to open the disk (whether or not it still does). | — |
| `one_time_unlock` | The disk opens by itself at the next start, with nothing checked: `setup` left this for the restart after it, and it goes at that start. | `false` is the goal. While it's `true`, restart the laptop. If it stays `true` after a restart, see [Troubleshooting](../guides/troubleshooting.md#setup-didnt-finish-at-the-restart). |
| `recovery_key` | The disk has a recovery key. | Run `setup`, or `recovery-key`. |
| `passphrase` | The disk can still be opened with a typed passphrase (usually the one chosen at install). | `false` is the goal. To remove it, run `setup` with the recovery key. |

### `boot_menu`

| Field | `true` means |
|---|---|
| `editor_locked` | Boot entries can't be edited at the boot menu. |
| `config_protected` | The boot menu refuses a menu file that was changed outside the update tools. |
| `fallback_protected` | The firmware's fallback boot loader is the protected one, not a plain copy. |

### `tpm_policy`

The TPM's record of which boot files may open the disk. It's made at the restart after `setup`, and kept up to date by
updates.

| Field | Meaning |
|---|---|
| `exists` | The TPM has a record of this laptop's boot files. `false` until the restart after `setup`. |
| `pcrs` | Which of the TPM's measurements it checks: `[4, 11]`, the boot loader with its menu, and the boot image. Not part of `protected`. |
| `current` | The record covers every boot file now on the laptop, so the next start needs nothing typed. When `false`, something changed a boot file outside the update tools: run `sudo monarchy-encryption reassert`. |
