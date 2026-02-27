#!/bin/bash
set -e

DATE=$(date +%F)
STATE_DIR="$HOME/state_backups"
MOON_LIVE_DB="$HOME/printer_data/database/moonraker-sql.db"
MOON_DB_DIR="$HOME/printer_data/database"
SPOOL_ROTATED_DB="$HOME/.local/share/spoolman/backups/spoolman.db"

mkdir -p "$STATE_DIR"

# -------------------------------
# Skip if printing
# -------------------------------
PRINT_STATE=$(curl -s http://localhost:7125/printer/objects/query?print_stats \
| grep -o '"state":"[^"]*"' | cut -d':' -f2 | tr -d '"')

if [[ "$PRINT_STATE" == "printing" ]]; then
    echo "Print in progress. Skipping backup."
    exit 0
fi

echo "Starting state backup for $DATE..."

# -------------------------------
# Moonraker backup
# -------------------------------
MOON_BACKUP="$STATE_DIR/moonraker-sql_$DATE.db"

sqlite3 "$MOON_LIVE_DB" \
".backup $MOON_BACKUP"

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
# Extract Moonraker Stats (from BACKUP)
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
# Human-friendly conversions
# -------------------------------

# Total print time formatting
TP_H=$((TOTAL_PRINT_SECONDS / 3600))
TP_M=$(((TOTAL_PRINT_SECONDS % 3600) / 60))

# Longest print formatting
LP_H=$((LONGEST_PRINT_SECONDS / 3600))
LP_M=$(((LONGEST_PRINT_SECONDS % 3600) / 60))

# Filament formatting
FILAMENT_M=$(awk "BEGIN {printf \"%.2f\", $TOTAL_FILAMENT_MM/1000}")

if (( TOTAL_FILAMENT_MM > 1000000 )); then
    FILAMENT_KM=$(awk "BEGIN {printf \"%.2f\", $TOTAL_FILAMENT_MM/1000000}")
    FILAMENT_DISPLAY="$FILAMENT_KM km"
else
    FILAMENT_DISPLAY="$FILAMENT_M m"
fi

# -------------------------------
# Extract Spoolman Stats
# -------------------------------

TOTAL_SPOOLS=$(sqlite3 "$SPOOL_BACKUP" \
"SELECT COUNT(*) FROM spool WHERE archived IS NULL OR archived = 0;")

LAST_SPOOL=$(sqlite3 "$SPOOL_BACKUP" \
"SELECT filament.name
 FROM spool
 JOIN filament ON spool.filament_id = filament.id
 WHERE spool.last_used IS NOT NULL
 ORDER BY spool.last_used DESC
 LIMIT 1;")

# -------------------------------
# Generate Clean README
# -------------------------------

README="$STATE_DIR/README.md"

cat > "$README" <<EOF
# 🖨 Printer State Snapshot — $DATE

## 📊 Moonraker Statistics

• **Total Jobs Completed:** $TOTAL_JOBS  
• **Total Print Time:** ${TP_H}h ${TP_M}m  
• **Longest Print:** ${LP_H}h ${LP_M}m  
• **Total Filament Consumed:** $FILAMENT_DISPLAY  
• **Last Print File:** \`$LAST_JOB\`

---

## 🧵 Spoolman Overview

• **Active Spools Registered:** $TOTAL_SPOOLS  
• **Most Recently Used Spool:** $LAST_SPOOL  

---

_Generated automatically by state_backup.sh_
EOF

cd "$STATE_DIR"

git add .
git diff --cached --quiet || git commit -m "State backup $DATE"
git push origin master

echo "State backup complete."