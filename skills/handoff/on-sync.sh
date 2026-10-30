#!/bin/bash
# Run by the sync engine after each sync: starts the handoff runs due on this computer and tells
# the sender when one of its notes changed status.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff.sh" on-sync
