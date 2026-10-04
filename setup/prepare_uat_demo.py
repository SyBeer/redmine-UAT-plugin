#!/usr/bin/env python3
"""Przygotowuje zadanie do ręcznego testu UAT: kryteria -> Gotowy do UAT -> 3 przypadki 'Do testu'.
Użytkownicy brani po rolach (loginy mogą być zmienione w UI).
Uruchomienie na RPi: python3 ~/redmine/setup/prepare_uat_demo.py
"""
import json, os, urllib.request, urllib.error

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
        return e.code, e.read()[:300]


ST = {s["name"]: s["id"] for s in api("GET", "/issue_statuses.json")[1]["issue_statuses"]}
CF = {c["name"]: c["id"] for c in api("GET", "/custom_fields.json")[1]["custom_fields"]}

by_role = {}
for m in api("GET", "/projects/pilotaz-dev/memberships.json?limit=100")[1]["memberships"]:
    if "user" in m:
        login = api("GET", f"/users/{m['user']['id']}.json")[1]["user"]["login"]
        for r in m["roles"]:
            by_role.setdefault(r["name"], []).append(login)
PO, DEV, BIZ = by_role["PO / Lead"][0], by_role["Developer"][0], by_role["Biznes (UAT)"][0]
print(f"PO: {PO}, Developer: {DEV}, Biznes: {BIZ}")

issues = api("GET", "/projects/pilotaz-dev/issues.json?status_id=*&limit=100")[1]["issues"]
target = next(i for i in issues if i["subject"].startswith("Walidacja NIP"))
iid = target["id"]
full = api("GET", f"/issues/{iid}.json?include=children")[1]["issue"]
print(f"Start: #{iid} {full['subject']} [{full['status']['name']}]")
assert not full.get("children"), f"#{iid} ma już podzadania - wybierz inne zadanie"

CRITERIA = """- Poprawny NIP: **Given** formularz nowego klienta, **When** wpisuję NIP 526-104-08-28, **Then** formularz zapisuje się bez błędu
- Błędna suma kontrolna: **Given** formularz nowego klienta, **When** wpisuję NIP 526-104-08-29, **Then** widzę komunikat „Nieprawidłowy NIP" i nie da się zapisać
- NIP ze spacjami i kreskami: **Given** formularz nowego klienta, **When** wpisuję „526 104 08 28", **Then** NIP zapisuje się jako 5261040828"""

dev_id = api("GET", f"/users.json?name={DEV}")[1]["users"][0]["id"]
code, _ = api("PUT", f"/issues/{iid}.json", {"issue": {
    "assigned_to_id": dev_id,
    "custom_fields": [{"id": CF["Kryteria akceptacji"], "value": CRITERIA}],
    "notes": "Kryteria akceptacji rozpisane na 3 przypadki testowe."}}, as_user=PO)
print(f"PO ustawia kryteria i przypisuje do {DEV}: HTTP {code}")
if full["status"]["name"] == "Nowy":
    api("PUT", f"/issues/{iid}.json", {"issue": {"status_id": ST["Gotowy"]}}, as_user=PO)
for s in ["W realizacji", "Code review", "Gotowy do UAT"]:
    code, _ = api("PUT", f"/issues/{iid}.json", {"issue": {"status_id": ST[s]}}, as_user=DEV)
    print(f"{DEV}: -> {s}: HTTP {code}")

full = api("GET", f"/issues/{iid}.json?include=children")[1]["issue"]
print(f"\nGotowe: #{iid} {full['subject']} [{full['status']['name']}], postęp {full['done_ratio']}%")
for c in full.get("children", []):
    ci = api("GET", f"/issues/{c['id']}.json")[1]["issue"]
    print(f"   #{ci['id']} {ci['subject']} [{ci['status']['name']}]")
