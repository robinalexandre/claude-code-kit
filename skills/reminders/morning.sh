#!/bin/bash
# Run by the daily-sync skill after the morning sync.
exec bash "$(dirname "${BASH_SOURCE[0]}")/reminders.sh" morning
