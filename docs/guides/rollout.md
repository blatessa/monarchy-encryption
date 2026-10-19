# Roll out to a fleet

An MDM can run every step. Every command reads its secret as one line on standard input and, with `--json`, answers
in JSON on standard output. One step still needs someone at the laptop: the disk passphrase, typed once at the restart
between the two runs of `setup` (an unattended restart is [planned](https://github.com/blatessa/monarchy-encryption/issues/37)).
Do it where the laptops are prepared, before they're handed out.

## The flow

1. **Install Omarchy unattended**, encrypted, with a **disk passphrase your MDM generates for this laptop**, separate
   from the user's password (omarchy-iso's README, "Unattended installs": `encryption_password` in
   `user_credentials.json` and in `disk_encryption` in `user_configuration.json`). Don't use Omarchy's "install for a
   later owner" mode: its first-boot setup re-keys the disk and removes this tool's keys
   ([status and limits](../status.md)).
2. **Clear the firmware's Secure Boot keys** (setup mode). Many fleet laptops can be ordered or configured that way.
3. **Install the package** (`pacman -U` the release file, as in [Getting started](../getting-started.md)).
4. **First run**, with the disk passphrase. Store the recovery key it returns:

    ```bash
    printf '%s\n' "$DISK_PASSPHRASE" | monarchy-encryption setup --json
    # {"schema":1,"done":false,"recovery_key":"…","passphrase":"kept"}
    ```

5. **Restart, and type the disk passphrase** at the prompt, this one last time.
6. **Second run**, with the recovery key you stored:

    ```bash
    printf '%s\n' "$RECOVERY_KEY" | monarchy-encryption setup --json
    # {"schema":1,"done":true,"recovery_key":null,"passphrase":"removed"}
    ```

7. **Directory sign-in** with [monarchy-identity](https://docs.monarchy.run/monarchy-identity/guides/automation/).

`"done": false` always means "restart, then run setup again". Running `setup` on a laptop that's done changes nothing
and needs no input, so an MDM can run it on every check-in.

## Checking a laptop

```bash
monarchy-encryption status --json
```

`protected` is `true` when everything `setup` does is in place. When it's `false`, `missing` says what to fix. Every
field: [Status output](../reference/status-output.md).

## Recovery keys

The recovery key is shown once, by `setup`'s first run or by `recovery-key`. Store it with the laptop's record:
there's no other copy. Replacing it (`recovery-key --json`) needs no secret once the TPM unlocks the disk, and the old
key stops working. A replacement by anyone with `sudo` on the laptop leaves a line in its journal
(`journalctl -t monarchy-encryption`).
