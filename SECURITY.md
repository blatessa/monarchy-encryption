# Security policy

monarchy-encryption decides what unlocks a laptop's disk, so security reports are taken seriously.

**Report vulnerabilities privately** with GitHub's [Report a vulnerability](https://github.com/blatessa/monarchy-encryption/security/advisories/new),
not a public issue. Include the version, what you did, what you expected, and the impact.

Especially interesting:

- the TPM releasing the disk key for software this laptop didn't sign, or with Secure Boot off;
- getting a shell or an editable kernel command line at boot on a set-up laptop;
- a recovery key or passphrase reaching the disk, the journal, a log or a process's arguments;
- a command removing the last key that opens a disk;
- an unprivileged user changing the disk's keys or the boot files.

Security fixes go into the latest release.
