# CLI

```text
monarchy-encryption <command>
```

| Command | Who | What |
|---|---|---|
| [`setup [--json]`](#setup) | root | TPM unlock for this laptop's own boot files, and a recovery key; finished by itself at the next start |
| [`status [--json]`](#status) | anyone | Whether the disk is protected, and what's missing |
| [`recovery-key [--json]`](#recovery-key) | root | Create or replace the recovery key |
| [`release`](#release) | root | Undo `setup`: a disk passphrase again, the TPM no longer opens the disk |
| [`reassert`](#reassert) | root | Put back boot settings an update undid (run by a pacman hook) |
| [`boot`](#boot) | root | Tell the TPM which boot files started, and finish `setup` (run by a service at every start) |

Commands that need root say so and stop. Exit status is 0 on success and 1 on any refusal or failure; messages go to
standard error and to the journal (`journalctl -t monarchy-encryption`).

**Secrets** (a disk passphrase, a recovery key) are asked for on a terminal, without echo. Without a terminal, they're
read from standard input, one per line. They're never accepted as arguments, which would put them in the process list
and the shell history.

## setup

Run it once, then restart (see [How it works](../concepts/how-it-works.md#why-a-restart)).

- **Before the restart**: asks for the disk passphrase, checks that the TPM can be tied to this laptop's boot files,
  switches to the boot environment TPM unlock needs, locks the boot menu, lets the TPM open the disk for the restart,
  then creates the recovery key and prints it. Nothing in the firmware settings changes.
- **At the restart**, with nothing typed, [`boot`](#boot) tells the TPM which boot files started, ties the disk to
  them and removes the disk passphrase.
- **Later runs** change nothing and ask for nothing, unless the TPM no longer opens the disk: then it asks for the
  recovery key and ties the disk to the TPM again. Given the recovery key, it also removes a disk passphrase that's
  still there.

`--json` prints one line:

```json
{"schema":1,"done":true,"recovery_key":null,"passphrase":"removed"}
```

| Field | |
|---|---|
| `done` | `false`: restart the laptop, and it finishes by itself |
| `recovery_key` | the new recovery key, when this run created one (store it now), else `null` |
| `passphrase` | `kept`, `removed` (this run removed it), or `none` (there was none) |

Without `--json`, the recovery key is the only thing on standard output.

## boot

Run by a service at every start; there's nothing to run by hand. It tells the TPM that the boot files that just
started are the ones to open the disk for (so a start after an update drops the files from before it). At the start
after `setup`, it then ties the disk to the TPM, checks the TPM opens it, and removes the disk passphrase; whatever
happens, it removes what let the disk open by itself for that start. Its messages are in the journal
(`journalctl -t monarchy-encryption`).

## status

```bash
monarchy-encryption status [--json]
```

Read-only; needs no secret. Run it as root for the full answer. Every field: [Status output](status-output.md).

## recovery-key

```bash
sudo monarchy-encryption recovery-key [--json]
```

Adds a new recovery key, checks it opens the disk, prints it, then removes the previous one. Once the TPM unlocks the
disk it asks for nothing; before that, it asks for the disk passphrase or the current recovery key. `--json`:

```json
{"schema":1,"recovery_key":"…","previous_key":"removed"}
```

`previous_key` is `none` (there wasn't one), `removed`, or `not_removed` (the new key works, but the old one still does
too: run it again).

## release

```bash
sudo monarchy-encryption release
```

Asks for a new disk passphrase (twice on a terminal, or one line on standard input) and adds it, removes the TPM from
the disk and the TPM's record of this laptop's boot files, and stops keeping them up to date. When the TPM no longer
opens the disk, it also needs the recovery key (on standard input, as the second line). The disk stays encrypted. Run it before Omarchy's factory reset; `setup` sets the laptop up again afterwards.

## reassert

```bash
sudo monarchy-encryption reassert
```

Puts back what an update undid: the boot environment settings, the boot menu settings and hooks, and the TPM's record
of the boot files the laptop will start next. It needs no secret and never touches the disk's keys. A pacman hook runs it after package updates; there's no need to run
it by hand. It does nothing before `setup`, after `release`, or while Omarchy's first-boot setup is pending.
