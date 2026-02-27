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
# Extract Last Print Thumbnail
# -------------------------------

THUMB_PATH=$(sqlite3 "$MOON_BACKUP" \
"SELECT json_extract(metadata, '$.thumbnails[2].relative_path')
 FROM job_history
 ORDER BY end_time DESC
 LIMIT 1;")

# Remove quotes
THUMB_PATH=$(echo "$THUMB_PATH" | tr -d '"')

if [[ -n "$THUMB_PATH" ]]; then
    SOURCE_THUMB="$HOME/printer_data/gcodes/$THUMB_PATH"
    DEST_THUMB="$STATE_DIR/last_print.png"

    if [[ -f "$SOURCE_THUMB" ]]; then
        cp "$SOURCE_THUMB" "$DEST_THUMB"
    else
        echo "Thumbnail file not found at $SOURCE_THUMB"
    fi
else
    echo "No thumbnail found in metadata."
fi

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

# -------------------------------
# Extract Spoolman Info (robust)
# -------------------------------

SPOOL_ROW=$(sqlite3 -separator "|" "$SPOOL_BACKUP" "
SELECT filament.name,
       filament.color_hex,
       filament.material,
       CAST((spool.initial_weight - spool.used_weight) AS INTEGER),
       CAST(spool.initial_weight AS INTEGER),
       CAST(spool.used_weight AS INTEGER)
FROM spool
JOIN filament ON spool.filament_id = filament.id
WHERE spool.last_used IS NOT NULL
ORDER BY spool.last_used DESC
LIMIT 1;
")

IFS="|" read -r SPOOL_NAME SPOOL_COLOR SPOOL_MATERIAL REMAINING INITIAL_WEIGHT USED_WEIGHT <<< "$SPOOL_ROW"

# Calculate remaining percentage
REMAINING_PERCENT=$(awk "BEGIN {if ($INITIAL_WEIGHT > 0) printf \"%.0f\", ($REMAINING / $INITIAL_WEIGHT) * 100; else print 0}")

# Fallback if no color
if [[ -z "$SPOOL_COLOR" ]]; then
    SPOOL_COLOR="#999999"
fi

# Lighten the color for the used portion (apply opacity/tint)
USED_COLOR="#E0E0E0"

# Calculate arc endpoints for remaining filament ring (progress ring style)
# Full circle is 360 degrees, we show remaining as a partial ring
ARC_ANGLE=$(awk "BEGIN {printf \"%.1f\", ($REMAINING_PERCENT / 100) * 360}")

# For SVG arc, we need x,y of arc endpoint
# Using parametric circle: x = cx + r*cos(angle), y = cy + r*sin(angle)
# Starting from top (270 degrees) going clockwise
PI=3.14159265359
START_ANGLE=$(awk "BEGIN {printf \"%.1f\", 270 * $PI / 180}")
END_ANGLE=$(awk "BEGIN {printf \"%.1f\", (270 + $ARC_ANGLE) * $PI / 180}")

# For simplicity, we'll use stroke-dasharray to show the percentage
# Calculate the circumference of the filament ring (radius ~65)
CIRCUMFERENCE=$(awk "BEGIN {printf \"%.1f\", 2 * 3.14159 * 65}")
DASH_LENGTH=$(awk "BEGIN {printf \"%.1f\", $CIRCUMFERENCE * ($REMAINING_PERCENT / 100)}")

# Generate SVG spool image - realistic spool with filament level indicator
SPOOL_SVG="$STATE_DIR/last_spool.svg"

# Calculate filament height based on percentage (0-100% maps to different radii)
# Empty spool: inner radius = 30 (just the core), Full spool: outer radius = 70
MIN_RADIUS=30
MAX_RADIUS=70
FILAMENT_RADIUS=$(awk "BEGIN {printf \"%.1f\", $MIN_RADIUS + (($MAX_RADIUS - $MIN_RADIUS) * ($REMAINING_PERCENT / 100))}")

# Darken color for shading
DARK_COLOR=$(echo "$SPOOL_COLOR" | sed 's/#//' | awk '{r=sprintf("%d","0x"substr($0,1,2)); g=sprintf("%d","0x"substr($0,3,2)); b=sprintf("%d","0x"substr($0,5,2)); printf "#%02x%02x%02x", int(r*0.7), int(g*0.7), int(b*0.7)}')

# Prepare symmetric layout and filament rectangle parameters (avoid heavy nested awk in heredoc)
LEFT_X=100
RIGHT_X=200
CORE_X=$LEFT_X
CORE_W=100
CORE_Y=80
CORE_H=140
# Filament visual thickness and extents
FIL_RX=$(awk "BEGIN {printf \"%.1f\", $FILAMENT_RADIUS * 0.5}")
FIL_H=$(awk "BEGIN {printf \"%.1f\", 100 + 2*($FILAMENT_RADIUS - 30)}")
FIL_Y=$(awk "BEGIN {printf \"%.1f\", $CORE_Y + ( ($CORE_H - $FIL_H)/2 )}")

cat > "$SPOOL_SVG" <<EOF
<svg width="300" height="300" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300">
  <defs>
    <!-- Gentle gradient for filament to avoid banding -->
    <linearGradient id="filamentGradient" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:$SPOOL_COLOR;stop-opacity:0.92" />
      <stop offset="50%" style="stop-color:$SPOOL_COLOR;stop-opacity:1" />
      <stop offset="100%" style="stop-color:$DARK_COLOR;stop-opacity:0.9" />
    </linearGradient>
    <radialGradient id="flangeGradient">
      <stop offset="0%" style="stop-color:#666;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#333;stop-opacity:1" />
    </radialGradient>
    <linearGradient id="coreGradient" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:#555;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#444;stop-opacity:1" />
    </linearGradient>
  </defs>

  <!-- Back flange (solid) -->
  <ellipse cx="$LEFT_X" cy="150" rx="60" ry="60" fill="url(#flangeGradient)"/>
  <circle cx="$LEFT_X" cy="150" r="24" fill="url(#coreGradient)"/>

  <!-- Core cylinder body -->
  <rect x="$CORE_X" y="$CORE_Y" width="$CORE_W" height="$CORE_H" fill="url(#coreGradient)" rx="6"/>
  
  <!-- Filament bundle (rounded rectangle) -->
  <rect x="$LEFT_X" y="$FIL_Y" width="$CORE_W" height="$FIL_H" rx="24" fill="url(#filamentGradient)"/>
  <!-- Filament end caps to smooth edges -->
  <ellipse cx="$LEFT_X" cy="$(awk "BEGIN {print $FIL_Y + $FIL_H/2}")" rx="$FIL_RX" ry="$(awk "BEGIN {printf \"%.1f\", $FIL_H/2}")" fill="$SPOOL_COLOR"/>
  <ellipse cx="$RIGHT_X" cy="$(awk "BEGIN {print $FIL_Y + $FIL_H/2}")" rx="$FIL_RX" ry="$(awk "BEGIN {printf \"%.1f\", $FIL_H/2}")" fill="$DARK_COLOR"/>

  <!-- Subtle texture: thin evenly spaced strokes to suggest winding, low opacity to avoid banding -->
  <g stroke="$DARK_COLOR" stroke-width="0.6" stroke-opacity="0.08">
EOF

# Add a modest set of texture lines programmatically (even spacing) to avoid heavy banding
TEXT_TOP=$(awk "BEGIN {printf \"%.0f\", $FIL_Y}")
TEXT_BOTTOM=$(awk "BEGIN {printf \"%.0f\", $FIL_Y + $FIL_H}")
for ((y=$TEXT_TOP+4; y<=$TEXT_BOTTOM-4; y+=6)); do
  echo "  <line x1=\"$LEFT_X\" y1=\"$y\" x2=\"$RIGHT_X\" y2=\"$y\"/>" >> "$SPOOL_SVG"
done

cat >> "$SPOOL_SVG" <<EOF
  </g>

  <!-- Front flange (semi-transparent so filament is visible) -->
  <ellipse cx="$RIGHT_X" cy="150" rx="60" ry="60" fill="url(#flangeGradient)" opacity="0.45"/>
  <circle cx="$RIGHT_X" cy="150" r="24" fill="url(#coreGradient)" opacity="0.6"/>
  <!-- Spokes on front flange -->
  <g stroke="#666" stroke-width="3" stroke-opacity="0.6">
    <line x1="$RIGHT_X" y1="150" x2="$RIGHT_X" y2="110"/>
    <line x1="$RIGHT_X" y1="150" x2="$RIGHT_X" y2="190"/>
    <line x1="$RIGHT_X" y1="150" x2="${RIGHT_X-40}" y2="150"/>
    <line x1="$RIGHT_X" y1="150" x2="${RIGHT_X+40}" y2="150"/>
  </g>

</svg>
EOF

# -------------------------------
# Generate Clean README
# -------------------------------

README="$STATE_DIR/README.md"

cat > "$README" <<EOF
# 🖨 Printer State Snapshot — $DATE

## 📊 Moonraker Statistics

![Last Print Thumbnail](./last_print.png)

• **Total Jobs Completed:** $TOTAL_JOBS  
• **Total Print Time:** ${TP_H}h ${TP_M}m  
• **Longest Print:** ${LP_H}h ${LP_M}m  
• **Total Filament Consumed:** $FILAMENT_DISPLAY  
• **Last Print File:** \`$LAST_JOB\`

---

## 🧵 Spoolman Overview

![Last Used Spool](./last_spool.svg)

• **Name:** $SPOOL_NAME  
• **Material:** $SPOOL_MATERIAL  
• **Remaining Weight:** ${REMAINING}g  
• **Active Spools:** $TOTAL_SPOOLS 

---

_Generated automatically by state_backup script_
EOF

echo "Updated Readme and Assets states"

# echo "Committing and Pushing to Github!"

# cd "$STATE_DIR"

# git add .
# git diff --cached --quiet || git commit -m "State backup $DATE"
# git push origin master

# echo "State backup complete."