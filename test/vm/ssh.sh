#!/bin/bash
# ssh into the lab VM as the lab user: test/vm/ssh.sh [COMMAND...]. sudo's password is the disk passphrase (lib.sh).
source "$(dirname "$0")/lib.sh"
exec ssh -i "$KEY" -p "$SSH_PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR "$LAB_USER@127.0.0.1" "$@"
