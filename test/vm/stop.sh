#!/bin/bash
# Shut the lab VM down cleanly (its state is kept for the next run.sh).
source "$(dirname "$0")/lib.sh"
stop_vm "$LAB"
