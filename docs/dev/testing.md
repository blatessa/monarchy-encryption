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
commands (`test/unit/stubs/`: `cryptsetup`, `sbctl`, `systemd-cryptenroll`, `bootctl`, `limine-update`, `logger`)
first on `PATH`. The sandbox is a stock Omarchy laptop: an ESP (`$T/boot`) with Omarchy's `limine.conf` and boot
files, its `/etc/default/limine` (`test/unit/fixtures/`), and firmware variables (`$T/efivars`) in setup mode.
The disk's keyslots are `$T/state/keyslots` (the passphrase in slot 0), which the `cryptsetup` and
`systemd-cryptenroll` stubs both read and change. `me` gives the CLI the sandbox passphrase on stdin, as a caller does; `me_in INPUT ARGS` runs it with another line and keeps
stdout (`OUT`) apart from stderr (`ERR`). Each stub appends its command line to `$STUB_LOG`; `called "cryptsetup open"` checks what they saw. A suite puts the
files it needs under `$T/etc` itself, so suites don't depend on each other or on order.

Stubs start as "record and succeed". When a feature needs a tool's real output, the stub learns it, controlled by a
`STUB_*` variable, and `docs/dev/findings.md` says where that output was observed. When a lab run shows a stub was
wrong, fix the stub and the note.

| Suite | Covers |
|---|---|
| `cli` | Every command exists, `--help`, unknown commands and options, root checks; the PKGBUILD installs every library the CLI loads; the harness itself (stubs shadow the real tools and record calls) |
| `initramfs` | The drop-in's hook mapping against Omarchy's real hook config (plain, NVIDIA-only, non-Latin layout, unknown hooks), the crypttab line, refusals that change nothing, re-running that rebuilds nothing, `status` |
| `secureboot` | `setup`'s Secure Boot part: keys, signing before enrolling, the boot menu settings, the fallback hook, re-running, every refusal leaving the machine unchanged, `status --json` |
| `reassert` | `reassert` and the editor hook: nothing to do before setup or when nothing changed; Omarchy's menu copied over ours stays locked through `limine-update`; an unsigned Limine, the enroll setting, the drop-in, a missing hook and an unsigned boot image put back; a stale TPM reported, no key touched; the pacman hook's name, action and triggers |
| `tpm` | `setup`'s two runs: the recovery key last in the first; after the restart, the TPM bound to PCR 7 and proven; the passphrase removed only in a run unlocked with the recovery key; a stale TPM slot enrolled afresh; no TPM, a TPM that doesn't open the disk, a wrong or missing passphrase: refused with the keyslots unchanged; `status` |
| `recoverykey` | `recovery-key`: created and replaced, unlocked by the passphrase, the current recovery key or the TPM; the new key proven before the old one is removed; the key on stdout or in JSON and nowhere else; refusals that leave the keyslots alone |

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
test/vm/install-package.sh   # build the package from this checkout and install it in the running VM
test/vm/boot-loop.sh N LABEL # reboot N times, typing the passphrase; counts boots that never come up
test/vm/hibernate-loop.sh N LABEL  # hibernate N times; counts real resumes (unreliable in the lab: #21)
```

Lab suites (each resets the lab first):

| Suite | Covers |
|---|---|
| `test/vm/e2e-initramfs.sh` | `setup` on a clean install: the themed passphrase screen, systemd opens the disk, re-running changes nothing (boot image included), a snapshot starts writable; hibernation is reported, not counted, until #21 |
| `test/vm/e2e-recoverykey.sh` | `recovery-key` after `setup`: the key opens the disk and starts the laptop when typed at the disk prompt; replaced, the old one opens nothing; the passphrase is kept; the key isn't in the journal or on disk; a wrong passphrase changes nothing |
| `test/vm/e2e-updates.sh` | On a laptop that's fully set up: a kernel update, a limine upgrade, `omarchy-refresh-limine` and a simulated migration each leave it starting with nothing typed from its Limine entry, everything signed, the menu locked (no Edit on screen) and enrolled |
| `test/vm/e2e-tpm.sh` | `setup`'s two runs end with the laptop starting with nothing typed; the passphrase removed with the recovery key; a kernel update still unlocks; Secure Boot off (OVMF without Secure Boot) and a changed db bring back the prompt, which the recovery key opens; setup then enrolls the TPM afresh |
| `test/vm/e2e-secureboot.sh` | `setup` on a clean install; Secure Boot on after a restart; the menu has no editor; an unsigned EFI program is refused; a kernel update stays signed; a snapshot taken before setup is reported, one taken after starts; a changed menu is refused |

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
- **No serial port.** The VM has none unless `LAB_SERIAL=1` (`install.sh` sets it, to see when the install is done).
  With one, the firmware's console list and systemd's UKI stub add `console=` for it, and Plymouth shows a plain-text
  disk prompt instead of Omarchy's themed one (findings.md). For kernel messages while debugging a boot, set
  `LAB_SERIAL=1` and read `serial.log`.
- **Ports and files.** ssh is forwarded on 127.0.0.1:2223 (monarchy-identity's lab uses 2222). Each running VM keeps
  `qmp.sock`, `swtpm.log` and screenshots (and `serial.log` with `LAB_SERIAL=1`) in its directory. Everything under
  `test/vm/images/` and `test/vm/keys/` is git-ignored.
