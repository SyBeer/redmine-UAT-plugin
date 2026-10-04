#!/usr/bin/env python3
"""Test przebiegu UAT z przypadkami testowymi (podzadania) przez REST API.
Tworzy zadania tymczasowe, przechodzi pełną ścieżkę, na końcu je usuwa.
Użytkownicy brani po rolach (loginy mogą być zmienione w UI).
Uruchomienie na RPi: python3 ~/redmine/setup/test_uat.py
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
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except ValueError:
            return e.code, {"raw": raw[:200].decode(errors="replace")}


ST = {s["name"]: s["id"] for s in api("GET", "/issue_statuses.json")[1]["issue_statuses"]}
TR = {t["name"]: t["id"] for t in api("GET", "/trackers.json")[1]["trackers"]}
CF = {c["name"]: c["id"] for c in api("GET", "/custom_fields.json")[1]["custom_fields"]}
PRIO = {p["name"]: p["id"] for p in api("GET", "/enumerations/issue_priorities.json")[1]["issue_priorities"]}

by_role = {}
for m in api("GET", "/projects/pilotaz-dev/memberships.json?limit=100")[1]["memberships"]:
    if "user" in m:
        login = api("GET", f"/users/{m['user']['id']}.json")[1]["user"]["login"]
        for r in m["roles"]:
            by_role.setdefault(r["name"], []).append(login)
PO, DEV, BIZ = by_role["PO / Lead"][0], by_role["Developer"][0], by_role["Biznes (UAT)"][0]
AC, LINK, NOTES = CF["Kryteria akceptacji"], CF["Link do środowiska UAT"], CF["Uwagi z UAT"]
URL1, URL2 = "https://uat.example.com/eksport", "https://uat2.example.com/eksport"


def get(iid, extra=""):
    return api("GET", f"/issues/{iid}.json?include=children{extra}")[1]["issue"]


def status(iid):
    return get(iid)["status"]["name"]


def cf(issue, fid):
    return next((c.get("value") for c in issue.get("custom_fields", []) if c["id"] == fid), None)


def move(iid, st, user, extra=None):
    body = {"status_id": ST[st]}
    body.update(extra or {})
    return api("PUT", f"/issues/{iid}.json", {"issue": body}, as_user=user)


def tests_of(iid):
    kids = sorted(c["id"] for c in get(iid).get("children", []))
    return [i for i in (get(k) for k in kids) if i["tracker"]["name"] == "Test UAT"]


def errors(r):
    return " ".join(r.get("errors", [])) if isinstance(r, dict) else str(r)


def create(subject, criteria):
    code, r = api("POST", "/issues.json", {"issue": {
        "project_id": "pilotaz-dev", "tracker_id": TR["Funkcjonalność"], "priority_id": PRIO["Wysoki"],
        "subject": subject, "custom_fields": [{"id": AC, "value": criteria}]}}, as_user=PO)
    assert code == 201, r
    return r["issue"]["id"]


results = []


def check(desc, ok, info=""):
    results.append(ok)
    print(("  PASS  " if ok else "  FAIL  ") + desc + (f"  [{info}]" if info and not ok else ""))


CRITERIA = """- Eksport pustej listy
  - Gdzie: Umowy → Lista umów
  - Kroki:
    1. Ustaw filtr „Klient: brak wyników"
    2. Kliknij „Eksport CSV"
  - Dane: login uat_sprzedaz
  - Oczekiwane: pobiera się plik z samym nagłówkiem
- Eksport 10 000 umów: **Given** 10 000 umów w filtrze, **When** eksportuję, **Then** plik ma 10 000 wierszy
- Polskie znaki w Excelu
  - Gdzie: Umowy → Lista umów
  - Kroki:
    1. Wyszukaj klienta „Żółć Sp. z o.o."
    2. Eksportuj i otwórz CSV w Excelu
  - Oczekiwane: polskie znaki wyświetlają się poprawnie"""

temp = []
try:
    print(f"Użytkownicy: PO={PO}, DEV={DEV}, BIZ={BIZ}\n")
    # --- A1: nieuzupełniony szablon blokuje wyjście z "Nowy" ---
    code, r = api("POST", "/issues.json", {"issue": {
        "project_id": "pilotaz-dev", "tracker_id": TR["Funkcjonalność"],
        "subject": "TEST-UAT szablon (do usunięcia)"}}, as_user=PO)
    tmpl = r["issue"]["id"]; temp.append(tmpl)
    check("nowe zadanie dostaje szablon w kryteriach", "[nazwa przypadku]" in (cf(get(tmpl), AC) or ""))
    code, r = move(tmpl, "Gotowy", PO)
    check("BLOKADA: nieuzupełniony szablon nie przejdzie do 'Gotowy'",
          code == 422 and status(tmpl) == "Nowy" and "szablon" in errors(r), f"{code} {errors(r)}")

    # --- A2: link obowiązkowy przy "Gotowy do UAT" ---
    iid = create("TEST-UAT tymczasowe (do usunięcia)", CRITERIA); temp.append(iid)
    move(iid, "Gotowy", PO)
    for s in ["W realizacji", "Code review"]:
        move(iid, s, DEV)
    code, r = move(iid, "Gotowy do UAT", DEV)
    check("BLOKADA: bez linku do UAT nie da się oddać do testów",
          code == 422 and status(iid) == "Code review", f"{code} {errors(r)}")
    code, r = move(iid, "Gotowy do UAT", DEV, {"custom_fields": [{"id": LINK, "value": URL1}]})
    check("z linkiem przechodzi do 'Gotowy do UAT'", status(iid) == "Gotowy do UAT", f"{code} {errors(r)}")

    tc = tests_of(iid)
    check("powstały 3 przypadki TC1..TC3 w statusie 'Do testu'",
          len(tc) == 3 and [t["subject"][:4] for t in tc] == ["TC1:", "TC2:", "TC3:"]
          and all(t["status"]["name"] == "Do testu" for t in tc), [t["subject"] for t in tc])
    check("każdy przypadek ma link do UAT", all(cf(t, LINK) == URL1 for t in tc), [cf(t, LINK) for t in tc])
    d1 = tc[0]["description"]
    check("szablon sformatowany: tytuł, Gdzie, Kroki 1-2, Dane, Oczekiwane",
          all(x in d1 for x in ["### Eksport pustej listy", "**Gdzie:** Umowy → Lista umów", "**Kroki:**",
                                "1. Ustaw filtr", "2. Kliknij", "**Dane:**", "**Oczekiwane:**"]), d1)
    check("stary format Given/When/Then nadal działa", "**Given**" in tc[1]["description"])
    check("priorytet rodzica bez zmian (Wysoki)", get(iid)["priority"]["name"] == "Wysoki")
    t1, t2, t3 = (t["id"] for t in tc)

    # --- przebieg UAT ---
    move(t1, "Zaliczony", DEV)
    check("developer nie ustawi wyniku testu", status(t1) == "Do testu", status(t1))
    move(iid, "UAT w toku", BIZ)
    move(t1, "Zaliczony", BIZ)
    move(t2, "Zaliczony", BIZ)
    move(t3, "Niezaliczony", BIZ, {"custom_fields": [{"id": NOTES, "value": "Krzaki zamiast ż i ó."}]})
    check("biznes ustawia wyniki (2 zaliczone, 1 niezaliczony z uwagą)",
          [status(t1), status(t2), status(t3)] == ["Zaliczony", "Zaliczony", "Niezaliczony"]
          and cf(get(t3), NOTES) == "Krzaki zamiast ż i ó.")
    check("postęp rodzica ~67%", 60 <= get(iid)["done_ratio"] <= 70, get(iid)["done_ratio"])
    code, r = move(iid, "UAT zaakceptowany", BIZ)
    check("BLOKADA: akceptacja z niezaliczonym testem",
          code == 422 and status(iid) == "UAT w toku" and f"#{t3}" in errors(r), f"{code} {errors(r)}")

    move(iid, "UAT odrzucony", BIZ)
    for s in ["W realizacji", "Code review"]:
        move(iid, s, DEV)
    move(iid, "Gotowy do UAT", DEV, {"custom_fields": [{"id": LINK, "value": URL2}]})
    check("po poprawce niezaliczony wraca do 'Do testu', zaliczone zostają",
          [status(t1), status(t2), status(t3)] == ["Zaliczony", "Zaliczony", "Do testu"])
    check("nowy link trafił do wszystkich przypadków, bez duplikatów",
          len(tests_of(iid)) == 3 and all(cf(get(t), LINK) == URL2 for t in (t1, t2, t3)))

    move(iid, "UAT w toku", BIZ)
    move(t3, "Zaliczony", BIZ)
    code, r = move(iid, "UAT zaakceptowany", BIZ)
    check("wszystkie zaliczone -> akceptacja przechodzi, postęp 100%",
          status(iid) == "UAT zaakceptowany" and get(iid)["done_ratio"] == 100, f"{code} {errors(r)}")
finally:
    for i in temp:
        api("DELETE", f"/issues/{i}.json")
check("zadania tymczasowe usunięte", all(api("GET", f"/issues/{i}.json")[0] == 404 for i in temp))

print(f"\nWynik: {sum(results)}/{len(results)} testów OK")
sys.exit(0 if all(results) else 1)
