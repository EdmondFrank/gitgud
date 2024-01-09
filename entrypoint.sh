#!/bin/sh

# Run SQL migrations
/app/bin/gitgud eval "GitGud.ReleaseTasks.migrate"

exec $@
