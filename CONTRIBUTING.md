# Contributing

Contributor and agent guidance lives in [AGENTS.md](AGENTS.md) (rules, scope, conventions),
[docs/dev/testing.md](docs/dev/testing.md) (the two test layers and the lab) and
[docs/dev/architecture.md](docs/dev/architecture.md) (decisions).

- **Never test on your own laptop.** A bad boot image, Secure Boot or keyslot change can leave a disk unbootable or
  unrecoverable. Use the lab in `test/vm/`.
- Run `test/unit/run.sh` (seconds, no setup) and the lab suites your change touches.
- Never remove the last way into a disk: prove another key opens it first, and test that.
- Update the docs (`docs/`) with behaviour changes and `docs/dev/findings.md` with lessons.

By contributing you agree your work is released under the MIT license in [LICENSE](LICENSE).
