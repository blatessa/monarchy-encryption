# Troubleshooting

Every refusal happens before anything is changed, unless it says otherwise. Messages are also in the journal:
`journalctl -t monarchy-encryption`.

## setup refuses

| Message starts with | What to do |
|---|---|
| "Secure Boot already has keys that aren't this laptop's own" | Clear the Secure Boot keys in the firmware settings ("reset to setup mode", "clear keys"), then run `setup` again. |
| "this laptop didn't start in UEFI mode" | Turn off legacy/CSM boot in the firmware settings. Omarchy installs for UEFI; a laptop that started otherwise can't use Secure Boot. |
| "this laptop has no TPM 2.0" | Turn the TPM on in the firmware settings (PTT on Intel, fTPM on AMD). |
| "Omarchy's first-boot setup hasn't finished" | Start the laptop and finish Omarchy's first-boot setup (create the user), then run `setup`. |
| "this needs the disk's recovery key or passphrase" | Give it on a terminal when asked, or as one line on standard input. |
| "that recovery key or passphrase doesn't open the disk" | Check it and try again. Type a recovery key exactly as it was printed, dashes included. |
| "…/etc/crypttab already describes the disk 'root' differently" | Someone set the disk up by hand. Remove that line, or make it the one the message shows, and run `setup` again. |
| "these boot files are still unsigned" | Something else writes boot files. Run `sudo limine-update`, then `setup` again; if it persists, open an issue with the file names. |

## setup didn't finish at the restart

`status` still says `opens by itself once: yes`, or the disk asked for its passphrase at the next start: look at
`journalctl -t monarchy-encryption`. "the laptop started without Secure Boot on" means the firmware didn't turn Secure
Boot on by itself: turn it on in the firmware settings, start the laptop (type the passphrase), then run
`sudo monarchy-encryption setup` with the recovery key.

## The laptop asks for the recovery key at every start

The TPM no longer vouches for the laptop: Secure Boot was turned off, or the firmware or its keys changed. Type the
recovery key, turn Secure Boot back on if it was turned off, then run `sudo monarchy-encryption setup` with the recovery
key. `status` shows this as `TPM unlocks it: no (enrolled, but the firmware or its keys changed …)`.

## status says "not protected"

`missing` (or the plain output's first line) lists what's wrong; [Status output](../reference/status-output.md) says
what each one means and what to do. Most are fixed by running `setup` again.

## The laptop doesn't start after an update

It shouldn't happen: updates are signed as they're built, and the pacman hook re-signs anything an update left
unsigned. If the firmware refuses to start the boot loader, choose the firmware's fallback boot entry (or "UEFI OS")
from its boot menu: it's a protected copy. Once started, run `sudo monarchy-encryption reassert` and open an issue with
what was updated.

## Before a factory reset

Run `sudo monarchy-encryption release` first. A reset without it leaves boot files the firmware refuses to start; if
that happened, clear the Secure Boot keys in the firmware settings and the laptop starts.
