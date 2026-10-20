# Roll out to a fleet

An MDM can run every step, with nobody at the keyboard. Every command reads its secret as one line on standard input
and, with `--json`, answers in JSON on standard output. Between `setup` and the restart after it, the laptop opens its
disk by itself, so do it where the laptops are prepared, before they're handed out, and restart straight away.

## The flow

1. **Install Omarchy unattended**, encrypted, with a **disk passphrase your MDM generates for this laptop**, separate
   from the user's password (omarchy-iso's README, "Unattended installs": `encryption_password` in
   `user_credentials.json` and in `disk_encryption` in `user_configuration.json`). Don't use Omarchy's "install for a
   later owner" mode: its first-boot setup re-keys the disk and removes this tool's keys
   ([status and limits](../status.md)).
2. **Clear the firmware's Secure Boot keys** (setup mode). Many fleet laptops can be ordered or configured that way.
3. **Update, then install the package**: `omarchy update` (a fresh install has no package lists yet), then `pacman -U`
   the release file, as in [Getting started](../getting-started.md).
4. **Set up**, with the disk passphrase. Store the recovery key it returns: it's the only copy, and once the laptop
   has restarted, the only way into the disk besides the TPM.

    ```bash
    printf '%s\n' "$DISK_PASSPHRASE" | monarchy-encryption setup --json
    # {"schema":1,"done":false,"recovery_key":"…","passphrase":"kept"}
    ```

5. **Restart.** Nothing to type: as the laptop starts, it ties the disk to the TPM and removes the disk passphrase.
   `status --json` then says `"protected": true`.
6. **Directory sign-in** with [monarchy-identity](https://docs.monarchy.run/monarchy-identity/guides/automation/).

`"done": false` means "restart the laptop". Running `setup` on a laptop that's done changes nothing and needs no input,
so an MDM can run it on every check-in.

## Checking a laptop

```bash
monarchy-encryption status --json
```

`protected` is `true` when everything `setup` does is in place. When it's `false`, `missing` says what to fix. Every
field: [Status output](../reference/status-output.md).

## Recovery keys

The recovery key is shown once, by `setup` or by `recovery-key`. Store it with the laptop's record:
there's no other copy. Replacing it (`recovery-key --json`) needs no secret once the TPM unlocks the disk, and the old
key stops working. A replacement by anyone with `sudo` on the laptop leaves a line in its journal
(`journalctl -t monarchy-encryption`).
