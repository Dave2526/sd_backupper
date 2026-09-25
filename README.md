# sd_backupper

*[English version](README.en.md)*

Shell-Skripte zum Sichern einer SD-Karte (per USB-Kartenleser) als komprimiertes
Image direkt auf eine per USB angeschlossene HDD — und zum Zurückschreiben
eines solchen Images auf ein Zielgerät.

> ⚠️ Beide Skripte schreiben mit `dd` auf Blockgeräte. Bei falscher Auswahl
> von Quelle/Ziel drohen Datenverluste. Geräteliste vor jeder Bestätigung
> genau prüfen.

## Funktionen

- Arbeitet **ausschließlich mit USB-Geräten** (erkannt über `TRAN=usb`) — interne
  Geräte werden nicht angezeigt.
- Quelle (SD-Karte) und Ziel (HDD) werden interaktiv aus einer Liste gewählt.
- Eventuell automatisch gemountete Partitionen der Quelle werden vor dem
  Imaging sauber ausgehängt.
- Das Image wird **direkt auf der HDD** erzeugt (kein Zwischenspeichern auf
  der SD, da diese i.d.R. zu klein ist).
- Mountpoint für die HDD wird bei Bedarf selbst angelegt.
- Unterordner auf der HDD: Auswahl aus vorhandenen Ordnern oder Eingabe eines
  neuen Namens.
- Dateiname-Vorschlag: `backup_YYYY-MM-DD.img` (frei änderbar).
- Prüfung, ob genug freier Speicher auf der HDD vorhanden ist.
- Komprimierung im Anschluss mit [PiShrink](https://github.com/Drewsif/PiShrink)
  (`-s`, damit auch Images anderer Distributionen als Raspberry Pi OS
  funktionieren).
- `pishrink.sh` wird beim ersten Lauf automatisch in den Skriptordner
  heruntergeladen, falls es nicht bereits vorhanden ist.
- Am Ende: Anzeige aller Dateien im gewählten Backup-Ordner sowie Abfrage,
  ob die HDD wieder ausgehängt werden soll (z.B. um vorher alte Backups
  manuell zu löschen).

## Voraussetzungen

- `bash`, `lsblk`, `dd`, `blockdev`, `findmnt`, `df`, `curl`, `gzip`, `parted`
- Root-Rechte (`sudo`)
- Internetverbindung beim ersten Lauf (für den PiShrink-Download)

## Installation

```bash
git clone https://github.com/Dave2526/sd_backupper.git ~/scripts/sd_backupper
cd ~/scripts/sd_backupper
chmod +x sd_backup.sh sd_restore.sh
```

`pishrink.sh` wird beim ersten Lauf von `sd_backup.sh` automatisch in
denselben Ordner heruntergeladen, falls es dort noch nicht liegt.

```
~/scripts/sd_backupper/
├── sd_backup.sh
├── sd_restore.sh
├── pishrink.sh      # wird automatisch nachgeladen
└── README.md
```

## Struktur der Ziel-HDD

Die Backup-Ordner müssen **direkt auf der 1. Ebene** der HDD-Partition
liegen — weitere Unterordner darunter werden von beiden Skripten nicht
erkannt (weder beim Anzeigen noch beim Suchen nach Images):

```
/ (Wurzel der HDD-Partition)
├── Arbeits-Pi/
│   ├── backup_2026-09-24.img
│   └── backup_2026-09-25.img
├── radio_kueche/
│   └── backup_2026-09-25.img
└── ...
```

Die Image-Dateien (`.img`/`.img.gz`) müssen wiederum direkt in ihrem
jeweiligen Ordner liegen, nicht in weiteren Unterordnern.

## Nutzung

```bash
cd ~/scripts/sd_backupper
sudo ./sd_backup.sh
```

Das Skript führt anschließend interaktiv durch:

1. Auswahl der Quelle (SD-Karte)
2. Auswahl der Ziel-HDD (und ggf. Partition)
3. Auswahl/Erstellung des Zielordners
4. Bestätigung des Dateinamens
5. Imaging (`dd`) + Komprimierung (`pishrink.sh -s`)
6. Anzeige vorhandener Backups + Abfrage zum Aushängen der HDD

## Restore (sd_restore.sh)

Schreibt ein zuvor erstelltes Image von der HDD zurück auf ein Zielgerät.

```bash
cd ~/scripts/sd_backupper
sudo ./sd_restore.sh
```

Ablauf:

1. Auswahl der HDD mit den Backups (wie beim Backup, inkl. automatischem
   Mounten bei Bedarf)
2. Auswahl des Unterordners und des gewünschten Images (`.img`/`.img.gz`)
3. Auswahl des Zielgeräts (z.B. neue SD-Karte)
4. Prüfung, ob das Image auf das Ziel passt
5. **Sicherheitsabfrage** (`[j/N]`), da alle Daten auf dem Ziel
   unwiderruflich überschrieben werden
6. Schreiben des Images (`dd`, bei `.img.gz` vorher `zcat`-Entpacken im
   Stream) und Abfrage zum Aushängen der HDD am Ende

## Hinweise

- Vor dem Start sicherstellen, dass Quelle und Ziel korrekt identifiziert
  werden — die Geräteliste zeigt Größe und Modell zur Kontrolle an.
- Der Vorgang mit `dd` legt eine neue Image-Datei an. Nur falls bereits eine
  Datei mit demselben Namen existiert (z.B. bei einem zweiten Backup am
  selben Tag mit unverändertem Namensvorschlag), wird diese überschrieben.
  Auf ausreichend Speicherplatz achten (Prüfung erfolgt automatisch).

## Lizenz

[MIT](LICENSE)

---

Erstellt mit [Claude](https://claude.ai) (Anthropic).
