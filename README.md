# redmine-UAT-plugin

Pilotaż Redmine jako backlogu zespołu DEV z odbiorem UAT przez biznes — wtyczka `uat_tests` + skrypty konfiguracji i testów.

**Wersja wtyczki:** 0.5.0 · **Redmine:** 6.1 (Docker) · **Status:** pilotaż, nie produkcja

## Po co

Zespół DEV (3 osoby) i biznes pracują w jednym narzędziu. Biznes odbiera gotowe zadania przez testy UAT: każdy przypadek testowy klika jako zaliczony lub niezaliczony, a funkcjonalności nie da się zaakceptować, dopóki któryś test nie przechodzi.

## Przebieg

```
Nowy → Gotowy → W realizacji → Code review → Gotowy do UAT → UAT w toku → UAT zaakceptowany → Zamknięty
                     ↑                                              │
                     └──────────────── UAT odrzucony ←──────────────┘
```

| Rola | Może |
|---|---|
| Developer | realizacja → „Gotowy do UAT"; poprawka po „UAT odrzucony" |
| Biznes (UAT) | „UAT w toku" → zaakceptowany / odrzucony; wyniki przypadków testowych |
| PO / Lead | wszystkie przejścia |

## Wtyczka `uat_tests`

Jeden plik: [`plugins/uat_tests/init.rb`](plugins/uat_tests/init.rb). Bez zależności i bez migracji bazy.

1. **Generuje przypadki testowe.** Gdy zadanie przechodzi do „Gotowy do UAT", z pola „Kryteria akceptacji" powstają podzadania typu **Test UAT** (status „Do testu"). Jeden przypadek = punkt listy bez wcięcia albo nagłówek (`**AC-006-1**`, `### …`). Tytuł z samego identyfikatora dostaje treść „Then".
2. **Blokuje akceptację.** „UAT zaakceptowany" jest niemożliwy, dopóki któryś przypadek nie jest „Zaliczony" — komunikat wskazuje blokujące przypadki.
3. **Ponowny test po poprawce.** Gdy zadanie wraca do „Gotowy do UAT", niezaliczone przypadki wracają do „Do testu", zaliczone zostają, link UAT jest aktualizowany.
4. **Pilnuje szablonu.** Nieuzupełniony szablon kryteriów (`[nazwa przypadku]`, `[krok 1]`…) blokuje wyjście ze statusu „Nowy".
5. **Link do UAT w nowej karcie** — w zadaniu, przypadkach i listach.
6. **Tablica Agile bez przypadków testowych** — ukryte, chyba że ktoś filtruje po typie „Test UAT".
7. **Błędy widoczne w zadaniu.** Jeśli przypadków nie da się utworzyć, w historii zadania pojawia się komentarz „⚠️ Nie udało się utworzyć przypadków testowych UAT: …". Zamknięta wersja (sprint) nie blokuje — przypadek powstaje bez wersji.
8. Sam włącza typ „Test UAT" w projekcie, w którym go brakuje.

### Szablon kryteriów akceptacji

```
- Eksport pustej listy
  - Gdzie: Umowy → Lista umów
  - Kroki:
    1. Ustaw filtr „Klient: brak wyników"
    2. Kliknij „Eksport CSV"
  - Dane: login uat_sprzedaz
  - Oczekiwane: pobiera się plik z samym nagłówkiem
```

Działa też format Given/When/Then w jednej linii albo bloki z nagłówkiem `**AC-xxx-n**`.

## Struktura

| Ścieżka | Co to |
|---|---|
| `docker-compose.yml` | Redmine 6.1 + PostgreSQL 16, port 3001 |
| `.env.example` | wzór `.env` (hasło bazy, `SECRET_KEY_BASE`) |
| `backup.sh` | `pg_dump` + załączniki, retencja 14 (cron 02:30) |
| `plugins/uat_tests/` | wtyczka |
| `setup/setup.rb` | statusy, typy, role, workflow, pola, projekt, konta testowe — **ponowne uruchomienie resetuje hasła** |
| `setup/setup_agile.rb` | moduł Agile + uprawnienia |
| `setup/setup_no_smtp.rb` | tryb bez poczty: wyłączone maile, „Moja strona" per rola |
| `setup/setup_uat_tests.rb` | typ „Test UAT", statusy, workflow, filtry, link obowiązkowy, szablon kryteriów |
| `setup/seed.py` | przykładowy backlog (tylko pusty projekt) |
| `setup/prepare_uat_demo.py` | zadanie demo z 3 przypadkami do ręcznego testu |
| `setup/test_uat.py` | test całej ścieżki UAT przez REST API (17 sprawdzeń) |
| `setup/test_uat_failures.rb` | test sytuacji awaryjnych (6 sprawdzeń, w wycofywanej transakcji) |
| `setup/jednorazowe/` | jednorazowe naprawy danych z pilotażu |

## Instalacja od zera

```bash
cp .env.example .env    # uzupełnij hasło bazy i SECRET_KEY_BASE (openssl rand -hex 64)
mkdir -p files plugins backups
docker compose up -d
docker compose exec -T redmine bin/rails runner /setup/setup.rb
```

Wtyczkę **RedmineUP Agile (Light)** pobierz ze strony redmineup.com (formularz z e-mailem) i rozpakuj do `plugins/redmine_agile` — nie ma jej w repozytorium. Potem:

```bash
docker compose restart redmine
docker compose exec -T redmine bin/rails runner /setup/setup_agile.rb
docker compose exec -T redmine bin/rails runner /setup/setup_no_smtp.rb
docker compose exec -T redmine bin/rails runner /setup/setup_uat_tests.rb
```

Skrypty Pythona wołają API kluczem admina z pliku `.admin_api_key`:

```bash
docker compose exec -T redmine bin/rails runner "print User.find_by_login('admin').api_key" > .admin_api_key
chmod 600 .admin_api_key
python3 setup/test_uat.py
```

## Wdrożenie na RPi (z repozytorium)

Redmine na RPi bierze wtyczkę i skrypty **bezpośrednio z klonu tego repozytorium** — nie ma osobnej kopii.

| Katalog na RPi | Co tam jest |
|---|---|
| `~/redmine-UAT-plugin/` | klon repozytorium (tylko odczyt, `git pull`) — wtyczka i `setup/` montowane stąd do kontenera |
| `~/redmine/` | dane i sekrety: `.env` (z `UAT_REPO`), `pgdata/`, `files/`, `backups/`, `plugins/redmine_agile/` |

Każda zmiana: **commit + push do Gitei → na RPi jedno polecenie:**

```bash
ssh raspi4@192.168.1.4 '~/redmine-UAT-plugin/update.sh'
```

`update.sh`: `git pull` → backup bazy → kopiuje zmieniony `docker-compose.yml` / `backup.sh` do `~/redmine` → restart Redmine → pokazuje wersję wtyczki → uruchamia `test_uat.py`.

Wycofanie zmiany: `git revert` w repo, push, ponownie `update.sh` (albo `git checkout v0.5.0` w klonie na RPi + restart).

## Utrzymanie

- Wtyczka modyfikuje model `Issue` i zapytanie tablicy Agile. **Po aktualizacji Redmine lub wtyczki Agile uruchom oba testy** — pokażą, co przestało działać.
- W Redmine 6 `init.rb` wtyczki wykonuje się już wewnątrz `to_prepare` — łatki dokładamy bezpośrednio, nie w kolejnym `to_prepare`.
- `bin/rails runner` w oficjalnym obrazie wymaga zmiennej `SECRET_KEY_BASE` w środowisku kontenera (jest w `docker-compose.yml`).
- Skrypty biorą użytkowników po rolach, nie po loginach — loginy można zmieniać w UI.
- `setup.rb` ma wpisany adres pilotażu (`Setting.host_name = '192.168.1.4:3001'`).

## Poza repozytorium (celowo)

`.env`, `credentials.txt`, `.admin_api_key`, `pgdata/`, `files/`, `backups/`, `plugins/redmine_agile/` — patrz `.gitignore`.
