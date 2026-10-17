#!/bin/bash
# One-time setup: create the repo, labels and starter issues, then delete this directory.
# Run from the repo root: bash .github/issues/create.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=blatessa/monarchy-encryption

git add -A
git commit -q -m "$(printf "Project plan: README, agent guide, research on Omarchy's disk and boot setup\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01SA34GhbfehGsi8J2r4pm1J")" || true
gh repo create "$REPO" --public --source . --push \
  --description "TPM disk unlock with Secure Boot and recovery keys for Omarchy laptops (part of the Monarchy suite)"

gh label create P0 --color b60205 --description "Blocks everything else" -R "$REPO" --force
gh label create P1 --color d93f0b --description "Needed to be usable" -R "$REPO" --force
gh label create P2 --color fbca04 --description "Makes it complete" -R "$REPO" --force
gh label create P3 --color 0e8a16 --description "Polish and decisions" -R "$REPO" --force
gh label create needs-lab --color ededed --description "Needs the VM lab to verify" -R "$REPO" --force

for f in .github/issues/[0-9]*.md; do
  title=$(sed -n 's/^title: "\(.*\)"$/\1/p' "$f")
  labels=$(sed -n 's/^labels: //p' "$f" | tr -d ' ')
  awk 'n>=2; /^---$/{n++}' "$f" | gh issue create -R "$REPO" --title "$title" --label "$labels" --body-file -
done
git rm -rq .github/issues && git commit -q -m "$(printf 'Starter issues filed\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01SA34GhbfehGsi8J2r4pm1J')" && git push -q
