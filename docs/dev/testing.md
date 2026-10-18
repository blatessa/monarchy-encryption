# Testing

Never test on a real machine: a bad initramfs, Secure Boot or keyslot change can leave a disk unbootable or
unrecoverable. Anything that needs real firmware, a TPM or an initramfs runs in the lab.

Agents and contributors: the working rules and definition of done are in [AGENTS.md](../../AGENTS.md).

## Two layers

| Layer | Runs | Needs | Covers |
|---|---|---|---|
| Fast (`test/unit/`) | seconds, every PR in CI | bash, `unshare -r` | Logic: the command surface, refusals, the files we write under `/etc`, the order and arguments of disk, TPM and boot commands, `status --json` |
| Lab (`test/vm/`) | minutes, locally | the VM | What only real firmware, a TPM and an initramfs can show: Secure Boot, TPM unlock, booting, recovery, surviving updates |

Put a check in the fast layer unless it needs the real thing. The fast layer is always required; the lab is required
when a change touches boot, keys or the initramfs.

## The fast layer

```bash
test/unit/run.sh                  # all of it
bash test/unit/cli.sh             # or one suite
```

`test/unit/lib.sh` gives each suite a sandbox: a temp `/etc` (`$T/etc`, passed as `MONARCHY_ENCRYPTION_ETC`), the
real `bin/monarchy-encryption` run as fake root (`unshare -r`, through `me`; `me_user` runs it unprivileged), and stub
commands (`test/unit/stubs/`: `cryptsetup`, `sbctl`, `systemd-cryptenroll`, `bootctl`, `logger`) first on `PATH`.
Each stub appends its command line to `$STUB_LOG`; `called "cryptsetup open"` checks what they saw. A suite puts the
files it needs under `$T/etc` itself, so suites don't depend on each other or on order.

Stubs start as "record and succeed". When a feature needs a tool's real output, the stub learns it, controlled by a
`STUB_*` variable, and `docs/dev/findings.md` says where that output was observed. When a lab run shows a stub was
wrong, fix the stub and the note.

| Suite | Covers |
|---|---|
| `cli` | Every command exists, `--help`, unknown commands and options, root checks; the harness itself (stubs shadow the real tools and record calls) |

## The lab

Not built yet: see issue #1 (a QEMU VM with Secure Boot firmware in setup mode, `swtpm`, and an encrypted Omarchy
install that can be reset in minutes).
