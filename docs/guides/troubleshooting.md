# Troubleshooting

Every refusal happens before anything is changed, unless it says otherwise. Messages are also in the journal:
`journalctl -t monarchy-encryption`.

## setup refuses

| Message starts with | What to do |
|---|---|
| "this laptop didn't start in UEFI mode" | Turn off legacy/CSM boot in the firmware settings. Omarchy installs for UEFI; a laptop that started otherwise can't have its boot measured. |
| "this laptop has no TPM 2.0" | Turn the TPM on in the firmware settings (PTT on Intel, fTPM on AMD). |
| "this laptop's TPM can't hold the boot policy" | The TPM is too old (before revision 1.38). A firmware update sometimes brings a newer one; otherwise this laptop can't use TPM unlock. |
| "this laptop's firmware records something at start that the TPM can't be tied to" | This firmware measures something the TPM policy can't describe, so TPM unlock can't work on it yet. Open an issue with the output of `sudo /usr/lib/systemd/systemd-pcrlock log`. |
| "Omarchy's first-boot setup hasn't finished" | Start the laptop and finish Omarchy's first-boot setup (create the user), then run `setup`. |
| "this needs the disk's recovery key or passphrase" | Give it on a terminal when asked, or as one line on standard input. |
| "that recovery key or passphrase doesn't open the disk" | Check it and try again. Type a recovery key exactly as it was printed, dashes included. |
| "…/etc/crypttab already describes the disk 'root' differently" | Someone set the disk up by hand. Remove that line, or make it the one the message shows, and run `setup` again. |
| "rebuilding the boot files failed (limine-update)" | The lines above it are Limine's tools' own error. Fix that (often a full ESP), then run `setup` again. |

## setup didn't finish at the restart

`status` still says `opens by itself once: yes`, or the disk asked for its passphrase at the next start: look at
`journalctl -t monarchy-encryption`. "setup can't finish without a TPM policy" means the TPM couldn't be told about
the boot files that started (the message before it says why): start the laptop (type the passphrase), then run
`sudo monarchy-encryption setup` with the recovery key.

## The laptop asks for the recovery key

Once, after a change to the boot files the update tools didn't make (or from a snapshot with an older boot image): type
the recovery key. The laptop tells the TPM about the boot files that started, and the next start needs nothing typed.

At every start: the TPM no longer holds what it needs (it was cleared in the firmware settings, or the mainboard was
replaced). Type the recovery key, then run `sudo monarchy-encryption setup` with it. `status` shows this as `TPM
unlocks it: no (enrolled, but it no longer opens the disk …)`.

## status says "not protected"

`missing` (or the plain output's first line) lists what's wrong; [Status output](../reference/status-output.md) says
what each one means and what to do. Most are fixed by running `setup` again.

## The laptop asks for the recovery key after an update

It shouldn't: the update tools tell the TPM about the new boot files as they build them. Type the recovery key, then
run `sudo monarchy-encryption status`. If `covers boot files` says `no`, run `sudo monarchy-encryption reassert`, and
open an issue with what was updated and the output of `journalctl -t monarchy-encryption`.

## Before a factory reset

Run `sudo monarchy-encryption release` first. Omarchy's reset asks for the disk passphrase, which `setup` removed;
`release` sets a new one. Without it, the recovery key should work at the reset's prompt and at the next start, but
that hasn't been tested.
