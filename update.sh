#!/bin/sh
# Wdrożenie z repozytorium na RPi: git pull -> backup -> synchronizacja compose/backup.sh -> restart -> testy.
# Uruchomienie na RPi: ~/redmine-UAT-plugin/update.sh
# Katalog z danymi Redmine (.env, pgdata, files): REDMINE_DIR, domyślnie ~/redmine
set -eu
REPO=$(cd "$(dirname "$0")" && pwd)
RUNTIME=${REDMINE_DIR:-$HOME/redmine}

cd "$REPO"
before=$(git rev-parse --short HEAD)
git pull --ff-only -q
echo "repo: $before -> $(git log -1 --format='%h %s')"

cd "$RUNTIME"
./backup.sh < /dev/null
echo "backup: $(ls -t backups/db_*.dump | head -1)"

for f in docker-compose.yml backup.sh; do
  if ! cmp -s "$REPO/$f" "$f"; then
    cp "$REPO/$f" "$f"
    echo "zaktualizowano $f"
  fi
done

# up -d odtwarza kontener tylko gdy zmienił się compose; restart przeładowuje wtyczkę
docker compose up -d < /dev/null 2>&1 | tail -1
docker compose restart redmine < /dev/null 2>&1 | tail -1
i=0
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/login)" = 200 ]; do
  i=$((i + 1))
  [ $i -gt 60 ] && { echo "Redmine nie wstał w 5 min - sprawdź: docker compose logs redmine"; exit 1; }
  sleep 5
done

docker compose exec -T redmine bin/rails runner \
  'p = Redmine::Plugin.find(:uat_tests); puts "wtyczka: #{p.name} #{p.version} (#{p.directory})"' \
  < /dev/null 2>/dev/null | grep wtyczka
python3 "$REPO/setup/test_uat.py" < /dev/null | tail -1
