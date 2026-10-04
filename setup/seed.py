#!/usr/bin/env python3
"""Zasiewa przykładowy backlog przez REST API i sprawdza workflow ról.
Uruchomienie na RPi: python3 ~/redmine/setup/seed.py  (klucz API admina w ~/redmine/.admin_api_key)
"""
import json, os, sys, urllib.request, urllib.error

BASE = "http://localhost:3001"
KEY = open(os.path.expanduser("~/redmine/.admin_api_key")).read().strip()


def api(method, path, body=None, as_user=None):
    req = urllib.request.Request(BASE + path, method=method,
                                 data=json.dumps(body).encode() if body else None)
    req.add_header("X-Redmine-API-Key", KEY)
    req.add_header("Content-Type", "application/json")
    if as_user:
        req.add_header("X-Redmine-Switch-User", as_user)
    try:
        with urllib.request.urlopen(req) as r:
            data = r.read()
            return r.status, (json.loads(data) if data else None)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def ids(path, key):
    return {x["name"]: x["id"] for x in api("GET", path)[1][key]}


ST = ids("/issue_statuses.json", "issue_statuses")
TR = ids("/trackers.json", "trackers")
VER = ids("/projects/pilotaz-dev/versions.json", "versions")
CF = {c["name"]: c["id"] for c in api("GET", "/custom_fields.json")[1]["custom_fields"]}
USERS = {u["login"]: u["id"] for u in api("GET", "/users.json?limit=100")[1]["users"]}
AC = CF["Kryteria akceptacji"]


def create(subject, tracker, desc, ac, version=None, priority=None):
    issue = {"project_id": "pilotaz-dev", "tracker_id": TR[tracker], "subject": subject,
             "description": desc, "custom_fields": [{"id": AC, "value": ac}]}
    if version:
        issue["fixed_version_id"] = VER[version]
    if priority:
        issue["priority_id"] = priority
    code, r = api("POST", "/issues.json", {"issue": issue}, as_user="po")
    assert code == 201, (code, r)
    return r["issue"]["id"]


def move(iid, status, user, extra=None):
    body = {"status_id": ST[status]}
    body.update(extra or {})
    code, r = api("PUT", f"/issues/{iid}.json", {"issue": body}, as_user=user)
    now = api("GET", f"/issues/{iid}.json")[1]["issue"]["status"]["name"]
    return code, now, r


if api("GET", "/projects/pilotaz-dev/issues.json?status_id=*")[1]["total_count"] > 0:
    sys.exit("Backlog już zasiany - pomijam.")

# --- Backlog ---
BACKLOG = [
    ("Logowanie przez SSO (Entra ID)", "Funkcjonalność", "Sprint 1", "Gotowy", "dev1"),
    ("Eksport listy umów do CSV", "Funkcjonalność", "Sprint 1", "Gotowy", "dev2"),
    ("Błąd: data zakończenia umowy przesunięta o 1 dzień (strefa czasowa)", "Błąd", "Sprint 1", "Gotowy", "dev3"),
    ("Walidacja NIP w formularzu klienta", "Funkcjonalność", "Sprint 1", "Gotowy", None),
    ("Powiadomienie e-mail o zbliżającym się końcu umowy", "Funkcjonalność", "Sprint 2", "Nowy", None),
    ("Dashboard: liczba aktywnych umów per oddział", "Funkcjonalność", "Sprint 2", "Nowy", None),
    ("Aktualizacja zależności frontendu (security)", "Zadanie", "Sprint 2", "Nowy", None),
    ("Błąd: paginacja gubi filtr po powrocie z widoku szczegółów", "Błąd", None, "Nowy", None),
    ("Uprawnienia: rola tylko-do-odczytu dla audytu", "Funkcjonalność", None, "Nowy", None),
    ("Testy E2E dla ścieżki zakładania klienta", "Zadanie", None, "Nowy", None),
]
created = []
for subj, tr, ver, status, who in BACKLOG:
    ac = (f"**Given** użytkownik z odpowiednimi uprawnieniami\n"
          f"**When** korzysta z funkcji: {subj.lower()}\n"
          f"**Then** wynik jest zgodny z opisem, bez błędów w logach")
    iid = create(subj, tr, f"Opis do uzupełnienia przez PO.\n\nŹródło: przykładowy backlog pilotażu.", ac, ver)
    extra = {"assigned_to_id": USERS[who]} if who else {}
    if status != "Nowy":
        code, now, r = move(iid, status, "po", extra)
        assert now == status, (subj, code, r)
    created.append(iid)
print(f"Utworzono {len(created)} zadań: #{created[0]}-#{created[-1]}")

# --- Test workflow (pełny przebieg + próby niedozwolone) ---
results = []

def check(desc, ok):
    results.append(ok)
    print(("  PASS  " if ok else "  FAIL  ") + desc)

i1 = created[0]
check("dev1: Gotowy -> W realizacji", move(i1, "W realizacji", "dev1")[1] == "W realizacji")
check("dev1: nie może przeskoczyć na 'UAT zaakceptowany'", move(i1, "UAT zaakceptowany", "dev1")[1] != "UAT zaakceptowany")
check("dev1: W realizacji -> Code review", move(i1, "Code review", "dev1")[1] == "Code review")
check("dev1: Code review -> Gotowy do UAT", move(i1, "Gotowy do UAT", "dev1",
      {"custom_fields": [{"id": CF["Link do środowiska UAT"], "value": "https://uat.example.com/sso"}]})[1] == "Gotowy do UAT")
check("dev1: nie może sam rozpocząć UAT", move(i1, "UAT w toku", "dev1")[1] != "UAT w toku")
check("biznes1: Gotowy do UAT -> UAT w toku", move(i1, "UAT w toku", "biznes1")[1] == "UAT w toku")
check("biznes1: UAT w toku -> UAT odrzucony", move(i1, "UAT odrzucony", "biznes1",
      {"custom_fields": [{"id": CF["Uwagi z UAT"], "value": "Po wylogowaniu sesja SSO zostaje aktywna."}]})[1] == "UAT odrzucony")
check("dev1: UAT odrzucony -> W realizacji (poprawka)", move(i1, "W realizacji", "dev1")[1] == "W realizacji")
for s, u in [("Code review", "dev1"), ("Gotowy do UAT", "dev1"), ("UAT w toku", "biznes1"), ("UAT zaakceptowany", "biznes1")]:
    move(i1, s, u)
check("po drugiej rundzie: UAT zaakceptowany", api("GET", f"/issues/{i1}.json")[1]["issue"]["status"]["name"] == "UAT zaakceptowany")
check("biznes1: nie może przenieść zadania do realizacji", move(created[3], "W realizacji", "biznes1")[1] != "W realizacji")

# Kryteria akceptacji wymagane od statusu Gotowy
code, r = api("POST", "/issues.json", {"issue": {"project_id": "pilotaz-dev", "tracker_id": TR["Zadanie"],
              "subject": "TEST bez kryteriów"}}, as_user="po")
tmp = r["issue"]["id"]
code, now, r = move(tmp, "Gotowy", "po")
check("PO: nie da się dać 'Gotowy' bez kryteriów akceptacji", now == "Nowy" and code == 422)
api("DELETE", f"/issues/{tmp}.json")

# Drugie zadanie zostawiamy w kolejce UAT dla biznesu
i2 = created[1]
for s in ["W realizacji", "Code review", "Gotowy do UAT"]:
    move(i2, s, "dev2")
check("dev2: zadanie #%d czeka na UAT" % i2, api("GET", f"/issues/{i2}.json")[1]["issue"]["status"]["name"] == "Gotowy do UAT")
move(created[2], "W realizacji", "dev3")

print(f"\nWynik: {sum(results)}/{len(results)} testów OK")
sys.exit(0 if all(results) else 1)
