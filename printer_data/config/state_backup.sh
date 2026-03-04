#!/bin/bash
set -e

DATE=$(date +%F)
STATE_DIR="$HOME/state_backups"
ASSETS_DIR="$STATE_DIR/assets"

MOON_LIVE_DB="$HOME/printer_data/database/moonraker-sql.db"
MOON_DB_DIR="$HOME/printer_data/database"
SPOOL_ROTATED_DB="$HOME/.local/share/spoolman/backups/spoolman.db"

mkdir -p "$STATE_DIR"

# -------------------------------
# Skip if printing
# -------------------------------
#PRINT_STATE=$(curl -s http://localhost:7125/printer/objects/query?print_stats \
#| grep -o '"state":"[^"]*"' | cut -d':' -f2 | tr -d '"')

#if [[ "$PRINT_STATE" == "printing" ]]; then
#    echo "Print in progress. Skipping backup."
#    exit 0
#fi

echo "Starting state backup for $DATE..."

# -------------------------------
# Moonraker backup
# -------------------------------
MOON_BACKUP="$STATE_DIR/moonraker-sql_$DATE.db"

sqlite3 "$MOON_LIVE_DB" ".backup $MOON_BACKUP"

cp "$MOON_DB_DIR/data.mdb" "$STATE_DIR/data_$DATE.mdb"
cp "$MOON_DB_DIR/lock.mdb" "$STATE_DIR/lock_$DATE.mdb"

# -------------------------------
# Spoolman backup (rotated copy)
# -------------------------------
if [[ ! -f "$SPOOL_ROTATED_DB" ]]; then
    echo "Spoolman rotated backup not found!"
    exit 1
fi

SPOOL_BACKUP="$STATE_DIR/spoolman_$DATE.db"
cp "$SPOOL_ROTATED_DB" "$SPOOL_BACKUP"

# -------------------------------
# Moonraker Stats (from BACKUP)
# -------------------------------

TOTAL_JOBS=$(sqlite3 "$MOON_BACKUP" \
"SELECT CAST(total AS INTEGER) FROM job_totals WHERE field='total_jobs';")

TOTAL_PRINT_SECONDS=$(sqlite3 "$MOON_BACKUP" \
"SELECT CAST(total AS INTEGER) FROM job_totals WHERE field='total_print_time';")

TOTAL_FILAMENT_MM=$(sqlite3 "$MOON_BACKUP" \
"SELECT CAST(total AS INTEGER) FROM job_totals WHERE field='total_filament_used';")

LONGEST_PRINT_SECONDS=$(sqlite3 "$MOON_BACKUP" \
"SELECT CAST(maximum AS INTEGER) FROM job_totals WHERE field='longest_print';")

LAST_JOB=$(sqlite3 "$MOON_BACKUP" \
"SELECT filename FROM job_history ORDER BY end_time DESC LIMIT 1;")

# -------------------------------
# Extract Last Print Thumbnail
# -------------------------------

THUMB_PATH=$(sqlite3 "$MOON_BACKUP" \
"SELECT json_extract(metadata, '$.thumbnails[#-1].relative_path')
 FROM job_history
 ORDER BY end_time DESC
 LIMIT 1;")

THUMB_PATH=$(echo "$THUMB_PATH" | tr -d '"')

if [[ -n "$THUMB_PATH" ]]; then
    SOURCE_THUMB="$HOME/printer_data/gcodes/$THUMB_PATH"
    DEST_THUMB="$STATE_DIR/last_print.png"
    [[ -f "$SOURCE_THUMB" ]] && cp "$SOURCE_THUMB" "$DEST_THUMB"
fi

# -------------------------------
# Human-friendly conversions
# -------------------------------

TP_H=$((TOTAL_PRINT_SECONDS / 3600))
TP_M=$(((TOTAL_PRINT_SECONDS % 3600) / 60))

LP_H=$((LONGEST_PRINT_SECONDS / 3600))
LP_M=$(((LONGEST_PRINT_SECONDS % 3600) / 60))

FILAMENT_M=$(awk "BEGIN {printf \"%.2f\", $TOTAL_FILAMENT_MM/1000}")

if (( TOTAL_FILAMENT_MM > 1000000 )); then
    FILAMENT_KM=$(awk "BEGIN {printf \"%.2f\", $TOTAL_FILAMENT_MM/1000000}")
    FILAMENT_DISPLAY="$FILAMENT_KM km"
else
    FILAMENT_DISPLAY="$FILAMENT_M m"
fi

# -------------------------------
# Spoolman Stats
# -------------------------------

TOTAL_SPOOLS=$(sqlite3 "$SPOOL_BACKUP" \
"SELECT COUNT(*) FROM spool WHERE archived IS NULL OR archived = 0;")

# Extract spool info (robust)
SPOOL_ROW=$(sqlite3 -separator "|" "$SPOOL_BACKUP" "
SELECT filament.name,
       filament.color_hex,
       filament.material,
       CAST(IFNULL(spool.initial_weight,0) AS INTEGER),
       CAST(IFNULL(spool.used_weight,0) AS INTEGER)
FROM spool
JOIN filament ON spool.filament_id = filament.id
WHERE spool.last_used IS NOT NULL
ORDER BY spool.last_used DESC
LIMIT 1;
")

IFS="|" read -r SPOOL_NAME SPOOL_COLOR SPOOL_MATERIAL INITIAL_WEIGHT USED_WEIGHT <<< "$SPOOL_ROW"

if [[ -z "$SPOOL_NAME" ]]; then
    SPOOL_NAME="N/A"
    SPOOL_MATERIAL="N/A"
    INITIAL_WEIGHT=0
    USED_WEIGHT=0
fi

REMAINING=$((INITIAL_WEIGHT - USED_WEIGHT))

if (( INITIAL_WEIGHT > 0 )); then
    PERCENT=$(( (REMAINING * 100) / INITIAL_WEIGHT ))
else
    PERCENT=0
fi

# Clamp percent
(( PERCENT < 0 )) && PERCENT=0
(( PERCENT > 100 )) && PERCENT=100

# Ensure color has #
if [[ -n "$SPOOL_COLOR" && "$SPOOL_COLOR" != \#* ]]; then
    SPOOL_COLOR="#$SPOOL_COLOR"
fi

[[ -z "$SPOOL_COLOR" ]] && SPOOL_COLOR="#999999"

# -------------------------------
# Generate Spool SVG from Template
# -------------------------------

TEMPLATE="$ASSETS_DIR/spool_template.svg"
OUTPUT="$STATE_DIR/last_spool.svg"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Template not found at $TEMPLATE"
    exit 1
fi

cp "$TEMPLATE" "$OUTPUT"

ESC_COLOR=$(printf '%s\n' "$SPOOL_COLOR" | sed 's/[&/\]/\\&/g')
ESC_PERCENT=$(printf '%s\n' "$PERCENT" | sed 's/[&/\]/\\&/g')

sed -i "s/{{FIL_COLOR}}/$ESC_COLOR/g" "$OUTPUT"
sed -i "s/{{PERCENT}}/$ESC_PERCENT/g" "$OUTPUT"

# -------------------------------
# Generate README
# -------------------------------
README="$STATE_DIR/README.md"

cat > "$README" <<EOF
# 🖨 Printer State Snapshot — $DATE

---

## 📊 Moonraker Statistics

<table>
<tr>
<td width="60%" valign="top">

<strong>Total Jobs Completed:</strong> $TOTAL_JOBS<br>
<strong>Total Print Time:</strong> ${TP_H}h ${TP_M}m<br>
<strong>Longest Print:</strong> ${LP_H}h ${LP_M}m<br>
<strong>Total Filament Consumed:</strong> $FILAMENT_DISPLAY<br>
<strong>Last Print File:</strong> <code>$LAST_JOB</code>

</td>

<td width="40%" align="right">
<img src="./last_print.png" width="260"/>
</td>
</tr>
</table>

---

## 🧵 Spoolman Overview

### 🟢 Last Used Spool

<table>
<tr>
<td width="45%" valign="top">
<img src="./last_spool.svg" width="260"/>
</td>

<td width="55%" valign="top">

<strong>Name:</strong> $SPOOL_NAME<br>
<strong>Material:</strong> $SPOOL_MATERIAL<br>
<strong>Remaining Weight:</strong> ${REMAINING}g<br>
<strong>Remaining Percent:</strong> ${PERCENT}%  

</td>
</tr>
</table>

---

### 📦 Spoolman Summary

<strong>Active Spools Registered:</strong> $TOTAL_SPOOLS

---

<div align="center" style="font-size:12px; opacity:0.6;">
Generated automatically by state_backup script
</div>

EOF

echo "Updated README and assets"

echo "Committing and Pushing to Github!"

cd "$STATE_DIR"

git add .
git diff --cached --quiet || git commit -m "State backup $DATE"
git push origin master

echo "State backup complete."
