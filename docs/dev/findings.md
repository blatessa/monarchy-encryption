# Findings

Non-obvious lessons, each with where it was seen. Newest last.

## Omarchy's unattended install needs the disk passphrase in `user_credentials.json`

Seen: Omarchy 4.0.5 release ISO (iso commit 3872d5a), October 2026, building the lab (`test/vm/install.sh`).

The omarchy-iso README says encryption is configured by the `disk_encryption` block in `user_configuration.json`.
With the passphrase only there, archinstall installs the disk **unencrypted** without a word. The install then halts
at its last phase ("Encrypted install but /mnt/boot/limine.conf has no cryptdevice="), because
`user_encrypt_installation.txt` said `true`. The configurator also writes the passphrase as `encryption_password` in
`user_credentials.json`, and that is the copy archinstall reads. Put it in both places.
