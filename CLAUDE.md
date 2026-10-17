@AGENTS.md

## Claude Code notes
- Shell state does not persist: use absolute paths; run long VM boots in the background (`setsid`), never `pkill -f`.
- Ask before anything outward-facing (pushing tags, releases, repo settings).
