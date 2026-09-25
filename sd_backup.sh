#!/usr/bin/env bash
#
# sd_backup.sh — Sichert eine per USB angeschlossene SD-Karte als Image
# direkt auf eine per USB angeschlossene HDD, anschließend Komprimierung
# mit pishrink (-s, da auch Nicht-Raspbian-Images gesichert werden können).
#
# Erwarteter Ablageort: ~/scripts/sd_backupper/sd_backup.sh
# pishrink.sh wird bei Bedarf automatisch in denselben Ordner geladen.
#
# Es werden ausschließlich USB-Geräte berücksichtigt. Mountpoints für die
# Ziel-HDD werden bei Bedarf selbst angelegt; am Ende wird gefragt, ob
# wieder ausgehängt werden soll.

set -euo pipefail

# ---------- Vorbedingungen ----------

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo/als root ausführen." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PISHRINK="$(command -v pishrink.sh || true)"
[[ -z "$PISHRINK" && -x /usr/local/bin/pishrink.sh ]] && PISHRINK="/usr/local/bin/pishrink.sh"
[[ -z "$PISHRINK" && -x "$SCRIPT_DIR/pishrink.sh" ]] && PISHRINK="$SCRIPT_DIR/pishrink.sh"

if [[ -z "$PISHRINK" ]]; then
    echo "pishrink.sh nicht gefunden — lade es nach $SCRIPT_DIR/pishrink.sh..."
    command -v curl >/dev/null 2>&1 || { echo "curl wird zum Nachladen benötigt." >&2; exit 1; }
    curl -fsSL https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh -o "$SCRIPT_DIR/pishrink.sh"
    chmod +x "$SCRIPT_DIR/pishrink.sh"
    PISHRINK="$SCRIPT_DIR/pishrink.sh"
fi

command -v gzip >/dev/null 2>&1 || { echo "gzip wird von pishrink benötigt (apt install gzip)." >&2; exit 1; }
command -v parted >/dev/null 2>&1 || echo "Hinweis: 'parted' fehlt eventuell — pishrink benötigt es (apt install parted)." >&2

for tool in lsblk dd blockdev findmnt df; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Benötigtes Tool '$tool' fehlt." >&2; exit 1; }
done

CREATED_MOUNT=""   # von uns angelegter Mountpoint (für Aufräumen am Ende)
MOUNTED_HERE=0     # ob wir selbst gemountet haben

cleanup_on_error() {
    if [[ $MOUNTED_HERE -eq 1 && -n "$CREATED_MOUNT" ]]; then
        echo "Fehler — versuche Mount wieder zu lösen: $CREATED_MOUNT"
        umount "$CREATED_MOUNT" 2>/dev/null || true
        rmdir "$CREATED_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup_on_error ERR

# ---------- Hilfsfunktionen ----------

MIN_SIZE_BYTES=$((5 * 1024 * 1024))  # Geräte < 5MB ausblenden (z.B. leerer Kartenleser)

# Listet USB-Festplatten (ganze Disks, keine Partitionen) mit Index, Größe in Bytes
list_usb_disks() {
    lsblk -dpbno NAME,TRAN,SIZE,MODEL 2>/dev/null | awk -v min="$MIN_SIZE_BYTES" '$2=="usb" && $3+0>=min'
}

# Lässt den Nutzer aus den USB-Disks (außer optional einer Ausschlussliste) wählen
select_usb_disk() {
    local prompt="$1"
    shift
    local exclude=("$@")
    local -a names=() sizes=() models=()
    local line name tran size model skip

    while IFS= read -r line; do
        name=$(awk '{print $1}' <<<"$line")
        size=$(awk '{print $3}' <<<"$line")
        model=$(cut -d' ' -f4- <<<"$line")

        skip=0
        for ex in "${exclude[@]:-}"; do
            [[ "$name" == "$ex" ]] && skip=1
        done
        [[ $skip -eq 1 ]] && continue

        names+=("$name")
        sizes+=("$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")")
        models+=("$model")
    done < <(list_usb_disks)

    if [[ ${#names[@]} -eq 0 ]]; then
        echo "Keine passenden USB-Geräte gefunden." >&2
        exit 1
    fi

    echo "$prompt" >&2
    for i in "${!names[@]}"; do
        printf "  [%d] %s  (%s)  %s\n" "$i" "${names[$i]}" "${sizes[$i]}" "${models[$i]}" >&2
    done

    local choice
    read -rp "Auswahl [0-$(( ${#names[@]} - 1 ))]: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice >= ${#names[@]} )); then
        echo "Ungültige Auswahl." >&2
        exit 1
    fi
    echo "${names[$choice]}"
}

# Hängt alle gemounteten Partitionen eines Geräts aus (nötig für sauberes dd)
unmount_disk_partitions() {
    local disk="$1"
    local part target
    while IFS= read -r part; do
        target=$(findmnt -n -o TARGET "$part" 2>/dev/null || true)
        if [[ -n "$target" ]]; then
            echo "Hänge $part von $target aus..."
            umount "$part"
        fi
    done < <(lsblk -lpno NAME,TYPE "$disk" | awk '$2=="part"{print $1}')
}

# ---------- Quelle wählen ----------

SRC=$(select_usb_disk "Zu sichernde SD-Karte wählen (Quelle):")
unmount_disk_partitions "$SRC"

SRC_SIZE=$(blockdev --getsize64 "$SRC")
echo "Quelle: $SRC ($(( SRC_SIZE / 1024 / 1024 / 1024 )) GiB)"

# ---------- Ziel wählen ----------

DST_DISK=$(select_usb_disk "Ziel-HDD wählen (nicht die Quelle):" "$SRC")

mapfile -t DST_PARTS < <(lsblk -lpno NAME,TYPE,FSTYPE "$DST_DISK" | awk '$2=="part"{print $1}')
if [[ ${#DST_PARTS[@]} -eq 0 ]]; then
    echo "Auf $DST_DISK wurde keine Partition gefunden." >&2
    exit 1
elif [[ ${#DST_PARTS[@]} -eq 1 ]]; then
    DST_PART="${DST_PARTS[0]}"
else
    echo "Partition auf der Ziel-HDD wählen:"
    for i in "${!DST_PARTS[@]}"; do
        printf "  [%d] %s\n" "$i" "${DST_PARTS[$i]}"
    done
    read -rp "Auswahl [0-$(( ${#DST_PARTS[@]} - 1 ))]: " pchoice
    DST_PART="${DST_PARTS[$pchoice]}"
fi

# Mount der Ziel-Partition sicherstellen (selbst anlegen, falls nötig)
DST_MOUNT=$(findmnt -n -o TARGET "$DST_PART" 2>/dev/null || true)
if [[ -z "$DST_MOUNT" ]]; then
    DST_MOUNT="/mnt/$(basename "$DST_PART")_backup"
    mkdir -p "$DST_MOUNT"
    mount "$DST_PART" "$DST_MOUNT"
    CREATED_MOUNT="$DST_MOUNT"
    MOUNTED_HERE=1
    echo "Ziel gemountet unter: $DST_MOUNT"
else
    echo "Ziel bereits gemountet unter: $DST_MOUNT"
fi

# ---------- Unterordner & Dateiname ----------

mapfile -t EXISTING_SUBDIRS < <(find "$DST_MOUNT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

if [[ ${#EXISTING_SUBDIRS[@]} -gt 0 ]]; then
    echo "Vorhandene Unterordner auf der HDD:"
    for i in "${!EXISTING_SUBDIRS[@]}"; do
        printf "  [%d] %s\n" "$i" "${EXISTING_SUBDIRS[$i]}"
    done
    echo "  [n] Neuen Ordner anlegen"
    read -rp "Auswahl: " SUBCHOICE
    if [[ "$SUBCHOICE" =~ ^[0-9]+$ ]] && (( SUBCHOICE >= 0 && SUBCHOICE < ${#EXISTING_SUBDIRS[@]} )); then
        SUBDIR="${EXISTING_SUBDIRS[$SUBCHOICE]}"
    else
        read -rp "Name des neuen Unterordners: " SUBDIR
    fi
else
    read -rp "Unterordner auf der HDD (z.B. Arbeits-Pi): " SUBDIR
fi

DEST_DIR="$DST_MOUNT/$SUBDIR"
mkdir -p "$DEST_DIR"

DEFAULT_NAME="backup_$(date +%F).img"
read -rep "Dateiname [$DEFAULT_NAME]: " FILENAME
FILENAME="${FILENAME:-$DEFAULT_NAME}"
IMG_PATH="$DEST_DIR/$FILENAME"

# ---------- Platzprüfung ----------

AVAIL_BYTES=$(df --output=avail -B1 "$DST_MOUNT" | tail -1 | tr -d ' ')
if (( AVAIL_BYTES < SRC_SIZE )); then
    echo "Nicht genug freier Speicher auf $DST_MOUNT ($(( AVAIL_BYTES / 1024 / 1024 / 1024 )) GiB frei, $(( SRC_SIZE / 1024 / 1024 / 1024 )) GiB benötigt)." >&2
    exit 1
fi

# ---------- Bestätigung ----------

echo
echo "Zusammenfassung:"
echo "  Quelle:      $SRC ($(( SRC_SIZE / 1024 / 1024 / 1024 )) GiB)"
echo "  Ziel-Datei:  $IMG_PATH"
echo "  Freier Platz: $(( AVAIL_BYTES / 1024 / 1024 / 1024 )) GiB"
echo
read -rp "Backup jetzt starten? [j/N]: " CONFIRM
if ! [[ "$CONFIRM" =~ ^[jJ]$ ]]; then
    echo "Abgebrochen."
    exit 0
fi

# ---------- Image erstellen ----------

echo "Erstelle Image: $SRC -> $IMG_PATH"
dd if="$SRC" of="$IMG_PATH" bs=4M status=progress conv=fsync

# ---------- Komprimieren ----------

echo "Komprimiere mit pishrink (-s)..."
"$PISHRINK" -s "$IMG_PATH"

echo "Fertig: $IMG_PATH"

# ---------- Aufräumen ----------

echo
echo "Inhalt von $DEST_DIR:"
ls -lh "$DEST_DIR"
echo

read -rp "HDD wieder aushängen? (n = gemountet lassen, z.B. um alte Backups zu löschen) [j/N]: " ANS
if [[ "$ANS" =~ ^[jJ]$ ]]; then
    umount "$DST_MOUNT"
    if [[ $MOUNTED_HERE -eq 1 ]]; then
        rmdir "$DST_MOUNT" 2>/dev/null || true
    fi
    echo "$DST_MOUNT ausgehängt."
else
    echo "$DST_MOUNT bleibt gemountet."
fi

trap - ERR
