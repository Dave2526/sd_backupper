#!/usr/bin/env bash
#
# sd_restore.sh — Schreibt ein zuvor mit sd_backup.sh erstelltes Image
# von einer per USB angeschlossenen HDD auf ein per USB angeschlossenes
# Zielgerät (z.B. SD-Karte) zurück.
#
# Erwarteter Ablageort: ~/scripts/sd_backupper/sd_restore.sh
#
# Es werden ausschließlich USB-Geräte berücksichtigt. Der Mount der
# Quell-HDD wird bei Bedarf selbst angelegt; am Ende wird gefragt, ob
# wieder ausgehängt werden soll. Vor dem eigentlichen Schreiben ist eine
# explizite Sicherheitsbestätigung nötig, da alle Daten auf dem Ziel
# unwiderruflich überschrieben werden.

set -euo pipefail

# ---------- Vorbedingungen ----------

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo/als root ausführen." >&2
    exit 1
fi

for tool in lsblk dd blockdev findmnt df numfmt; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Benötigtes Tool '$tool' fehlt." >&2; exit 1; }
done

CREATED_MOUNT=""
MOUNTED_HERE=0

cleanup_on_error() {
    if [[ $MOUNTED_HERE -eq 1 && -n "$CREATED_MOUNT" ]]; then
        echo "Fehler — versuche Mount wieder zu lösen: $CREATED_MOUNT"
        umount "$CREATED_MOUNT" 2>/dev/null || true
        rmdir "$CREATED_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup_on_error ERR

MIN_SIZE_BYTES=$((5 * 1024 * 1024))  # Geräte < 5MB ausblenden

# ---------- Hilfsfunktionen ----------

list_usb_disks() {
    lsblk -dpbno NAME,TRAN,SIZE,MODEL 2>/dev/null | awk -v min="$MIN_SIZE_BYTES" '$2=="usb" && $3+0>=min'
}

select_usb_disk() {
    local prompt="$1"
    shift
    local exclude=("$@")
    local -a names=() sizes=() bytes=() models=()
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
        bytes+=("$size")
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
    # Gibt "NAME BYTES" zurück (per $(...) einzusammeln, da Subshell)
    echo "${names[$choice]} ${bytes[$choice]}"
}

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

# ---------- Quell-HDD wählen & mounten ----------

read -r SRC_DISK _ <<< "$(select_usb_disk "HDD mit den Backups wählen (Quelle):")"

mapfile -t SRC_PARTS < <(lsblk -lpno NAME,TYPE,FSTYPE "$SRC_DISK" | awk '$2=="part"{print $1}')
if [[ ${#SRC_PARTS[@]} -eq 0 ]]; then
    echo "Auf $SRC_DISK wurde keine Partition gefunden." >&2
    exit 1
elif [[ ${#SRC_PARTS[@]} -eq 1 ]]; then
    SRC_PART="${SRC_PARTS[0]}"
else
    echo "Partition auf der Quell-HDD wählen:"
    for i in "${!SRC_PARTS[@]}"; do
        printf "  [%d] %s\n" "$i" "${SRC_PARTS[$i]}"
    done
    read -rp "Auswahl [0-$(( ${#SRC_PARTS[@]} - 1 ))]: " pchoice
    SRC_PART="${SRC_PARTS[$pchoice]}"
fi

SRC_MOUNT=$(findmnt -n -o TARGET "$SRC_PART" 2>/dev/null || true)
if [[ -z "$SRC_MOUNT" ]]; then
    SRC_MOUNT="/mnt/$(basename "$SRC_PART")_backup"
    mkdir -p "$SRC_MOUNT"
    mount "$SRC_PART" "$SRC_MOUNT"
    CREATED_MOUNT="$SRC_MOUNT"
    MOUNTED_HERE=1
    echo "Quelle gemountet unter: $SRC_MOUNT"
else
    echo "Quelle bereits gemountet unter: $SRC_MOUNT"
fi

# ---------- Unterordner wählen ----------

mapfile -t EXISTING_SUBDIRS < <(find "$SRC_MOUNT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
if [[ ${#EXISTING_SUBDIRS[@]} -eq 0 ]]; then
    echo "Keine Unterordner unter $SRC_MOUNT gefunden." >&2
    exit 1
fi

echo "Vorhandene Unterordner:"
for i in "${!EXISTING_SUBDIRS[@]}"; do
    printf "  [%d] %s\n" "$i" "${EXISTING_SUBDIRS[$i]}"
done
read -rp "Auswahl [0-$(( ${#EXISTING_SUBDIRS[@]} - 1 ))]: " subchoice
SUBDIR="${EXISTING_SUBDIRS[$subchoice]}"
SRC_DIR="$SRC_MOUNT/$SUBDIR"

# ---------- Image wählen ----------

mapfile -t IMAGES < <(find "$SRC_DIR" -maxdepth 1 -type f \( -name '*.img' -o -name '*.img.gz' \) -printf '%f\n' | sort)
if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "Keine .img/.img.gz Dateien in $SRC_DIR gefunden." >&2
    exit 1
fi

echo "Vorhandene Images in $SUBDIR:"
for i in "${!IMAGES[@]}"; do
    isize=$(stat -c%s "$SRC_DIR/${IMAGES[$i]}")
    printf "  [%d] %s  (%s)\n" "$i" "${IMAGES[$i]}" "$(numfmt --to=iec --suffix=B "$isize")"
done
read -rp "Auswahl [0-$(( ${#IMAGES[@]} - 1 ))]: " ichoice
IMG_NAME="${IMAGES[$ichoice]}"
IMG_PATH="$SRC_DIR/$IMG_NAME"
IMG_BYTES=$(stat -c%s "$IMG_PATH")

# ---------- Zielgerät wählen ----------

read -r DST DST_BYTES <<< "$(select_usb_disk "Zielgerät wählen (WIRD KOMPLETT ÜBERSCHRIEBEN):" "$SRC_DISK")"

unmount_disk_partitions "$DST"

if [[ "$IMG_NAME" != *.gz && $IMG_BYTES -gt $DST_BYTES ]]; then
    echo "Image ($(numfmt --to=iec --suffix=B "$IMG_BYTES")) ist größer als das Zielgerät ($(numfmt --to=iec --suffix=B "$DST_BYTES"))." >&2
    exit 1
fi
if [[ "$IMG_NAME" == *.gz ]]; then
    echo "Hinweis: komprimiertes Image — die tatsächliche Größe nach dem Entpacken kann nicht vorab geprüft werden."
fi

# ---------- Sicherheitsabfrage ----------

echo
echo "Zusammenfassung:"
echo "  Image:  $IMG_PATH"
echo "  Ziel:   $DST ($(numfmt --to=iec --suffix=B "$DST_BYTES"))"
echo
echo "ACHTUNG: Alle Daten auf $DST werden unwiderruflich überschrieben!"
read -rp "Restore jetzt starten? [j/N]: " CONFIRM
if ! [[ "$CONFIRM" =~ ^[jJ]$ ]]; then
    echo "Abgebrochen."
    exit 0
fi

# ---------- Restore ----------

if [[ "$IMG_NAME" == *.gz ]]; then
    echo "Entpacke und schreibe $IMG_PATH -> $DST ..."
    zcat "$IMG_PATH" | dd of="$DST" bs=4M status=progress conv=fsync
else
    echo "Schreibe $IMG_PATH -> $DST ..."
    dd if="$IMG_PATH" of="$DST" bs=4M status=progress conv=fsync
fi

sync
command -v partprobe >/dev/null 2>&1 && partprobe "$DST" || true

echo "Restore abgeschlossen."

# ---------- Aufräumen ----------

read -rp "Quell-HDD wieder aushängen? [j/N]: " ANS
if [[ "$ANS" =~ ^[jJ]$ ]]; then
    umount "$SRC_MOUNT"
    if [[ $MOUNTED_HERE -eq 1 ]]; then
        rmdir "$SRC_MOUNT" 2>/dev/null || true
    fi
    echo "$SRC_MOUNT ausgehängt."
else
    echo "$SRC_MOUNT bleibt gemountet."
fi

trap - ERR
