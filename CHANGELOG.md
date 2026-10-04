# Changelog

## [Wdrożenie] - 2026-10-04
### Zmienione
- RPi bierze wtyczkę i `setup/` bezpośrednio z klonu repozytorium (`UAT_REPO` w `.env`, montowanie tylko do odczytu).
### Dodane
- `update.sh` — wdrożenie jednym poleceniem: `git pull` → backup → synchronizacja compose → restart → testy.

## [0.5.0] - 2026-10-04
### Dodane
- Błąd tworzenia przypadków testowych widoczny w historii zadania („⚠️ Nie udało się utworzyć przypadków testowych UAT: …"), także przy braku kryteriów.
- Test sytuacji awaryjnych `setup/test_uat_failures.rb`.
### Zmienione
- Zamknięta lub zablokowana wersja (sprint) nie blokuje tworzenia przypadków — powstają bez wersji.

## [0.4.0] - 2026-10-04
### Dodane
- Link do środowiska UAT otwiera się w nowej karcie (zadanie, przypadki, listy).

## [0.3.0] - 2026-10-04
### Dodane
- Przypadki oddzielone nagłówkami (`**AC-006-1**`, `### …`); tytuł z samego identyfikatora dostaje treść „Then".
- Automatyczne włączenie typu „Test UAT" w projekcie, w którym go brakuje.
### Zmienione
- Filtry „Testy UAT do wykonania" i „Wyniki testów UAT" globalne (wszystkie projekty).

## [0.2.0] - 2026-10-04
### Dodane
- Link do środowiska UAT obowiązkowy od statusu „Gotowy do UAT", kopiowany do każdego przypadku i aktualizowany po poprawce.
- Szablon przypadku (Gdzie / Kroki / Dane / Oczekiwane) jako domyślna treść kryteriów; nieuzupełniony szablon blokuje wyjście ze statusu „Nowy".

## [0.1.0] - 2026-10-04
### Dodane
- Przypadki testowe UAT jako podzadania generowane z kryteriów akceptacji przy „Gotowy do UAT".
- Blokada „UAT zaakceptowany" przy niezaliczonych lub niewykonanych testach.
- Niezaliczone testy wracają do „Do testu" po ponownym oddaniu do UAT.
- Ukrycie przypadków testowych na tablicy Agile.
