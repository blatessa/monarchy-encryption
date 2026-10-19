# `status` output

`monarchy-encryption status` tells you whether a laptop's disk is protected the way `setup` leaves it, and if not,
what's missing. It only looks: it never changes anything, and it needs no passphrase or recovery key.

Run it as root (`sudo`) for the full answer. Without root it can still read the firmware's Secure Boot flags, but not
the disk's keys or the boot files, and those show as unknown.

## For a person

```text
$ sudo monarchy-encryption status
Protected:              no: disk.tpm_unlock
Disk encrypted:         yes
  ready for TPM unlock: yes
  TPM unlocks it:       no (enrolled, but the firmware or its keys changed: run setup with the recovery key)
  recovery key:         yes
  passphrase:           no
Secure Boot:            on
  this laptop's keys:   yes
  Microsoft keys:       yes
  boot files signed:    yes
Boot menu:
  entries locked:       yes
  menu protected:       yes
  fallback protected:   yes
```

## For an MDM or a script: `status --json`

One JSON object on one line. Check `protected` first. When it's `false`, `missing` names what to fix.

```json
{
  "schema": 1,
  "protected": true,
  "missing": [],
  "disk": {
    "encrypted": true, "systemd_initramfs": true,
    "tpm_unlock": true, "tpm_enrolled": true, "tpm_pcrs": [7],
    "recovery_key": true, "passphrase": false
  },
  "secure_boot": {
    "enabled": true, "setup_mode": false, "own_keys": true, "microsoft_keys": true, "boot_files_signed": true
  },
  "boot_menu": { "editor_locked": true, "config_protected": true, "fallback_protected": true }
}
```

Every value is `true`, `false`, or `null`. **`null` means unknown, never "no"**: usually because `status` didn't run
as root.

### The answer

| Field | Meaning |
|---|---|
| `schema` | The version of this format. It changes only when a field changes meaning or goes away; new fields can be added without changing it. |
| `protected` | `true` when everything below that `setup` takes care of is as it should be. `false` when anything is wrong (even if other things are unknown). `null` when nothing is wrong but something couldn't be checked. |
| `missing` | The fields that keep `protected` from being `true`, written as `section.field`, for example `"disk.tpm_unlock"`. Unknown fields aren't listed. `disk.no_passphrase` is listed when the disk still has a passphrase. |

### `disk`

| Field | `true` means | When it's `false` |
|---|---|---|
| `encrypted` | The system disk is encrypted. | `setup` can't help: reinstall with encryption. |
| `systemd_initramfs` | The laptop starts with the boot environment that can use the TPM. | Run `setup`. |
| `tpm_unlock` | The TPM opens the disk **right now**, so the laptop will start without asking for anything. | If `tpm_enrolled` is `true`, the firmware or its Secure Boot keys changed since `setup` (a firmware update, say): the laptop asks for the recovery key at start. Run `setup` with the recovery key. Otherwise run `setup`. |
| `tpm_enrolled` | The TPM has been set up to open the disk (whether or not it still does). | — |
| `tpm_pcrs` | Which measurements the TPM checks before opening the disk: `[7]` is Secure Boot's state. `null` when the TPM isn't set up. | — |
| `recovery_key` | The disk has a recovery key. | Run `setup`, or `recovery-key`. |
| `passphrase` | The disk can still be opened with a typed passphrase (usually the one chosen at install). | `false` is the goal. To remove it, run `setup` with the recovery key. |

### `secure_boot`

| Field | `true` means |
|---|---|
| `enabled` | Secure Boot is on: the firmware only starts signed software. |
| `setup_mode` | The firmware has no Secure Boot keys and accepts new ones (before `setup`). |
| `own_keys` | The firmware's Secure Boot keys are this laptop's own, created by `setup`. |
| `microsoft_keys` | Microsoft's keys are enrolled too (needed by some graphics cards and other devices). Not part of `protected`. |
| `boot_files_signed` | The boot loader, its fallback and every boot image are signed with this laptop's key. When `false` after `setup`, something rebuilt a boot file without signing it, and the laptop may not start. |

### `boot_menu`

| Field | `true` means |
|---|---|
| `editor_locked` | Boot entries can't be edited at the boot menu. |
| `config_protected` | The boot menu refuses a menu file that was changed outside the update tools. |
| `fallback_protected` | The firmware's fallback boot loader is the protected one, not a plain copy. |
