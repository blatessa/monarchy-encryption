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

A real, encrypted Omarchy install from the release ISO under QEMU/KVM, with Secure Boot firmware (OVMF's `secboot`
build, variables starting empty: setup mode, Secure Boot off) and a software TPM 2.0 (`swtpm`). It can be broken and put
back in seconds.

```bash
test/lab-check.sh        # what's missing, with the command that fixes it; exit 0 when the VM is up
test/vm/fetch-iso.sh     # once: the Omarchy release ISO (6 GB), checked against its SHA-256
test/vm/install.sh       # once per ISO: the clean install, unattended (about 10 minutes)
test/vm/run.sh           # boot the VM (types the disk passphrase); --no-passphrase when the TPM should unlock it
test/vm/ssh.sh [CMD]     # a shell or a command in the VM, as user lab (sudo password: lib.sh)
test/vm/stop.sh          # clean shutdown; disk, firmware variables and TPM state are kept
test/vm/reset.sh         # back to the clean install: disk, firmware variables (setup mode again) and TPM
```

Run long boots in the background (`setsid test/vm/install.sh </dev/null >install.log 2>&1 &`) rather than holding a
terminal.

How it fits together (`test/vm/lib.sh`):

- **Two copies.** `test/vm/images/base/` holds the clean install: disk, `vars.fd`, `tpm/`. Nothing writes to it after
  `install.sh`. `test/vm/images/lab/` is the working copy: a qcow2 overlay on the base disk plus its own copies of the
  variables and TPM state. `reset.sh` recreates it. A Secure Boot, keyslot or TPM experiment always resets all three
  together, because an enrolled TPM key that doesn't match the firmware state (or the other way round) is a different
  machine from the one you meant to test.
- **The unattended install.** The ISO installs itself when a drive labeled `cidata` carries its configurator's output
  files (omarchy-iso README, "Unattended installs"). `install.sh` writes those files for an encrypted full-disk
  install and adds `authorized_keys`, which also enables sshd. The cidata image holds the disk passphrase in plain
  text, so it is deleted once the install finishes.
- **The disk passphrase** is typed through QMP `send-key` on an interval until ssh answers, the same way Omarchy's
  own ISO tests do it. Plymouth's prompt can't be read reliably, and keystrokes that arrive early are discarded. The
  passphrase avoids keys that do something in Limine's menu (`e` edits the entry).
- **How it differs from a laptop.** As installed on 4.0.5, the lab matches a stock install: LUKS2 opened by the busybox
  `encrypt` hook (`cryptdevice=`), Limine with UKIs, Secure Boot off with the firmware in setup mode, TPM2 present.
  One known difference: the running kernel command line ends with `console=uart,io,0x3f8 console=tty0`, which isn't in
  Omarchy's Limine config. Where it comes from hasn't been traced yet.
- **Ports and files.** ssh is forwarded on 127.0.0.1:2223 (monarchy-identity's lab uses 2222). Each running VM keeps
  `qmp.sock`, `serial.log`, `swtpm.log` and screenshots in its directory. Everything under `test/vm/images/` and
  `test/vm/keys/` is git-ignored.
