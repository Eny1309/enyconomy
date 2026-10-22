# Enyconomy Web

Flips über deine Realms und Deals, aus den stündlichen Blizzard-Auktionsdaten und den TSM-Regionsdaten.

## Start (Docker)

    docker compose up -d --build
    docker logs -f enyconomy

Oberfläche: http://<host>:8080

Der erste Lauf dauert ein paar Minuten: Realm-Liste, Auktionen deiner Realms, TSM-Daten und
die Item-Namen werden geholt. Danach läuft alles automatisch jede Stunde. Fortschritt steht im Log
und im Tab "Status".

## Einstellungen (.env)

- `REALMS`: deine Realms, kommagetrennt, oder `all` für alle EU-Realm-Gruppen (deutlich mehr Download)
- `SCAN_MINUTES`: Abstand der Auktions-Abrufe (Blizzard aktualisiert ca. stündlich)
- `TSM_HOURS`: Abstand der TSM-Abrufe

Daten liegen in `./data/enyconomy.db` (SQLite). Löschen = alles neu holen.
- `DECOR_CLASS_ID`: Item-Klasse für Deko (Standard 20 = Behausung)
