#!/bin/sh
# Codzienny backup Redmine: zrzut bazy + załączniki, trzyma 14 ostatnich.
set -e
cd "$(dirname "$0")"
TS=$(date +%Y-%m-%d_%H%M)
docker compose exec -T db pg_dump -U redmine -Fc redmine </dev/null > "backups/db_$TS.dump"
tar -czf "backups/files_$TS.tgz" files
ls -1t backups/db_*.dump | tail -n +15 | xargs -r rm -f
ls -1t backups/files_*.tgz | tail -n +15 | xargs -r rm -f
