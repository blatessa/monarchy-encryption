# Testing

Never test on a real machine: a bad initramfs, boot file or keyslot change can leave a disk unbootable or
unrecoverable. Anything that needs real firmware, a TPM or an initramfs runs in the lab.

Agents and contributors: the working rules and definition of done are in [AGENTS.md](https://github.com/blatessa/monarchy-encryption/blob/main/AGENTS.md).

## Two layers

| Layer | Runs | Needs | Covers |
|---|---|---|---|
| Fast (`test/unit/`) | seconds, every PR in CI | bash, `unshare -r` | Logic: the command surface, refusals, the files we write under `/etc`, the order and arguments of disk, TPM and boot commands, `status --json` |
| Lab (`test/vm/`) | minutes, locally | the VM | What only real firmware, a TPM and an initramfs can show: measured boot, TPM unlock, booting, recovery, surviving updates |

Put a check in the fast layer unless it needs the real thing. The fast layer is always required; the lab is required
when a change touches boot, keys or the initramfs.

## The fast layer

```bash
test/unit/run.sh                  # all of it
bash test/unit/cli.sh             # or one suite
```

`test/unit/lib.sh` gives each suite a sandbox: a temp `/etc` (`$T/etc`, passed as `MONARCHY_ENCRYPTION_ETC`), the
real `bin/monarchy-encryption` run as fake root (`unshare -r`, through `me`; `me_user` runs it unprivileged), and stub
commands (`test/unit/stubs/`: `cryptsetup`, `systemd-cryptenroll`, `systemd-pcrlock`, `bootctl`, `limine-update`, `logger`)
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
| `cli` | Every command exists, `--help`, unknown commands and options, root checks; the PKGBUILD installs every library the CLI loads and the boot service where `setup` links it from; the harness itself (stubs shadow the real tools and record calls) |
| `initramfs` | The drop-in's hook mapping against Omarchy's real hook config (plain, NVIDIA-only, non-Latin layout, unknown hooks), the crypttab line, refusals that change nothing, re-running that rebuilds nothing, `status` |
| `boot` | `setup`'s boot part: the boot menu settings, the Limine hooks, the firmware's keys left alone; the TPM policy following updates (the files that started kept, at most two sets), rewritten from a start that missed it (the PIN), a change behind Limine's tools noticed and put right; a policy that can't be written warns without failing the update; refusals that change nothing; `status --json` |
| `status` | `status --json` from a stock install through `setup` and the restart after it (the one-time unlock): `protected` and `missing`, the TPM enrolled but no longer opening the disk, null without root, and changing nothing |
| `release` | `release`: the passphrase added via the TPM or the recovery key (or kept), proven before the TPM slot (or the one-time unlock) goes, then the TPM policy, the boot service and our hooks removed, in that order; never on a command line; refusals change nothing; `setup` afterwards |
| `provisioning` | Each of Omarchy's provisioning markers makes `setup` refuse with nothing changed; `status` reports it (also without root); `reassert` stands down; `setup` goes ahead once it's done |
| `reassert` | `reassert` and the editor hook: nothing to do before setup or when nothing changed; Omarchy's menu copied over ours stays locked through `limine-update`; a plain Limine, the enroll setting, the drop-in and a missing hook put back, the TPM policy rewritten when a boot file changed behind Limine's tools; a stale TPM reported, no key touched; the pacman hook's name, action and triggers |
| `tpm` | `setup` and the restart: the one-time unlock (bound to nothing, proven) and then the recovery key, last; `boot` with no input makes the policy, binds the TPM to it, proves it, removes the passphrase and then the one-time unlock, never makes a recovery key; the one-time unlock removed whatever happens (no policy, the TPM failing), the passphrase kept without a recovery key; `setup` by hand after the restart; a passphrase removed by hand only with the recovery key; a stale TPM slot enrolled afresh, the policy written into the TPM again first; no TPM, a TPM that can't hold the policy, unpredictable firmware, a wrong or missing passphrase: refused with the keyslots unchanged |
| `recoverykey` | `recovery-key`: created and replaced, unlocked by the passphrase, the current recovery key or the TPM; the new key proven before the old one is removed; the key on stdout or in JSON and nowhere else; refusals that leave the keyslots alone |

## The lab

A real, encrypted Omarchy install from the release ISO under QEMU/KVM, with UEFI firmware (OVMF's `secboot` build,
variables starting empty: no keys, Secure Boot off) and a software TPM 2.0 (`swtpm`). Real laptops have the
manufacturer's keys; setup leaves the keys alone, so the difference doesn't reach what's tested. A cleared TPM is
`images/base/tpm` copied over the lab's. It can be broken and put
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
test/vm/checkpoint.sh save NAME [UNLOCK] | restore NAME | list | clear   # lab states, for debugging (below)
test/vm/run-suites.sh [-j N] [SUITE...]  # suites side by side, a VM each; all of them by default (below)
```

**Run suites with `run-suites.sh`**: `test/vm/run-suites.sh tpm updates`, or no names for all of them. It builds the
package once, gives each suite its own VM (`images/lab-SUITE`, 4 GB, ssh on 2230 and up) and runs as many at once as
free memory allows (at most 4, or `-j N`), then prints each suite's result and time, and the failed checks. Logs:
`images/logs/`. A suite run on its own (`test/vm/e2e-tpm.sh`) uses the one lab VM, `images/lab`, as before.

Lab suites (each starts from a checkpoint: a clean install with the package, or a set-up laptop):

| Suite | Covers |
|---|---|
| `test/vm/e2e-initramfs.sh` | `setup` on a clean install: systemd opens the disk at the restart with nothing typed, the themed prompt (a cleared TPM) takes the recovery key, re-running changes nothing (boot image included), a snapshot starts writable with nothing typed. Hibernation is left to `hibernate-loop.sh` until #21 |
| `test/vm/e2e-recoverykey.sh` | `recovery-key` on a set-up laptop: replaced with nothing typed (the TPM); the key starts the laptop when typed at the disk prompt (a cleared TPM), and replaces itself there; the old one opens nothing; no key in the journal or on disk; a wrong key changes nothing; the laptop's own TPM still opens the disk |
| `test/vm/e2e-release.sh` | `release` on a set-up laptop, nothing of ours left running, restart with the new passphrase, Omarchy's factory reset and first-boot setup driven by keystrokes, then `setup` back to protected |
| `test/vm/e2e-provisioning.sh` | Omarchy's provisioning staged as a factory reset leaves it: the laptop unlocks itself with its key file, `setup` refuses and changes nothing so it keeps doing so, `status` says pending; once it's done, `setup` goes ahead |
| `test/vm/e2e-updates.sh` | On a laptop that's fully set up: a kernel update, a limine upgrade, `omarchy-refresh-limine` and a simulated migration each leave it starting with nothing typed from its Limine entry, the TPM policy covering the new files, the menu locked (no Edit on screen) and enrolled |
| `test/vm/e2e-tpm.sh` | `setup`, then a restart with nothing typed: the one-time unlock (bound to nothing) opens the disk, `boot` makes the policy, binds the TPM to it and removes the passphrase and the one-time unlock, the recovery key stays out of the journal and off the disk, the next start unlocks through the policy; a cleared TPM brings back the prompt, which the recovery key opens; setup then enrolls the TPM afresh; `status` before, during and after |
| `test/vm/e2e-boot.sh` | `setup` on a stock install, the firmware's keys untouched; the restart and the next with nothing typed, the policy over PCR 4 and 11; the menu has no editor; a plain Limine gets the disk prompt, and putting it back needs nothing typed again; a new boot image and a snapshot followed; the newest snapshot starts with nothing typed, one from before setup asks for the recovery key; a changed menu is refused |

Run long boots in the background (`setsid test/vm/install.sh </dev/null >install.log 2>&1 &`) rather than holding a
terminal.

**Checkpoints** make the loop shorter. A checkpoint is the VM's disk overlay, firmware variables and TPM state, saved
after a clean shutdown (copied with reflinks, so it takes seconds). Suites start from a precondition with
`checkpoint NAME BUILD`: restored when the package and the `BUILD` function are unchanged since it was saved, otherwise
built and saved; suites running side by side take turns (a lock), so one builds it and the others restore it.
`build_installed` (a clean install with this checkout's package) is where most suites start; `build_set_up` (a laptop
through `setup` and the restart after it) is the shared one for suites after setup. Only preconditions go in a
checkpoint, never what the suite is testing: `e2e-updates` starts from "set up", but no suite starts from a state its
own subject made. For debugging, `checkpoint.sh save NAME` the VM just before a failing step and `restore NAME` to
retry it; those are never rebuilt. Checkpoints live in `test/vm/images/checkpoints/` (git-ignored) with the values
their build made, such as the lab's recovery key; `checkpoint.sh clear` removes them.

How it fits together (`test/vm/lib.sh`):

- **Two copies.** `test/vm/images/base/` holds the clean install: disk, `vars.fd`, `tpm/`. Nothing writes to it after
  `install.sh`. `test/vm/images/lab/` is the working copy: a qcow2 overlay on the base disk plus its own copies of the
  variables and TPM state. `reset.sh` recreates it. A keyslot, policy or TPM experiment always resets all three
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
- **Ports and files.** ssh is forwarded on 127.0.0.1:2223 (monarchy-identity's lab uses 2222); `run-suites.sh` gives
  its VMs 2230 and up (`LAB_NAME`, `LAB_SSH_PORT`). Each running VM keeps
  `qmp.sock`, `swtpm.log` and screenshots (and `serial.log` with `LAB_SERIAL=1`) in its directory. Everything under
  `test/vm/images/` and `test/vm/keys/` is git-ignored.
