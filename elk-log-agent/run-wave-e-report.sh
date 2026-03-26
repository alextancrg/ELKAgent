#!/usr/bin/env bash
# Wave E Report Runner — generates the daily report with archive rotation.
#
# Flow:
#   1. Move existing reports from latest/ to archive/ (with date prefix)
#   2. Generate new report into latest/
#   3. Send Google Chat notification with download link
#
# Usage:
#   bash elk-report/run-wave-e-report.sh                    # Report for yesterday
#   bash elk-report/run-wave-e-report.sh 2026-03-24          # Specific date
#
# Environment variables:
#   ELK_PROD_APIKEY             — ELK Prod API key (required)
#   GOOGLE_CHAT_WEBHOOK_URL     — Google Chat webhook URL (optional)
#   ARCHIVE_RETENTION_DAYS      — Days to keep archived reports (default: 30)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LATEST_DIR="${SCRIPT_DIR}/latest"
ARCHIVE_DIR="${SCRIPT_DIR}/archive"
RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-30}"

mkdir -p "$LATEST_DIR" "$ARCHIVE_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# ── Step 1: Archive existing reports from latest/ ──
if ls "$LATEST_DIR"/*.html "$LATEST_DIR"/*.csv 2>/dev/null | grep -q .; then
    log "Archiving existing reports from latest/..."
    for f in "$LATEST_DIR"/*.html "$LATEST_DIR"/*.csv; do
        [ -f "$f" ] || continue
        mv "$f" "$ARCHIVE_DIR/"
        log "  Archived: $(basename "$f")"
    done
fi

# ── Step 2: Clean up old archives beyond retention period ──
if [ "$RETENTION_DAYS" -gt 0 ]; then
    OLD_COUNT=$(find "$ARCHIVE_DIR" -name "*.html" -o -name "*.csv" -mtime +"$RETENTION_DAYS" 2>/dev/null | wc -l)
    if [ "$OLD_COUNT" -gt 0 ]; then
        log "Cleaning up $OLD_COUNT archived reports older than ${RETENTION_DAYS} days..."
        find "$ARCHIVE_DIR" -name "*.html" -o -name "*.csv" -mtime +"$RETENTION_DAYS" -delete
    fi
fi

# ── Step 3: Generate new report into latest/ ──
log "Generating new Wave E report..."
REPORT_DIR="$LATEST_DIR" bash "$SCRIPT_DIR/daily_wave_e_report.sh" "$@"

log "Done."
log "  Latest:  $LATEST_DIR/"
log "  Archive: $ARCHIVE_DIR/"
