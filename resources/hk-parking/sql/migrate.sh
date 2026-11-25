#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# HK-PARKING migration runner — run ON hk-fxmain (.235) or via SSH.
# Backs up player_vehicles + player_parking, then applies hk_parking.sql
# (which migrates the 24 legacy parked cars into player_vehicles.location).
#
# Usage:  ./migrate.sh            # backup + migrate
#         ./migrate.sh --dry      # show what would migrate, change nothing
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

DB="homekong"
DBUSER="fivem"
DBPASS="Hp446876"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${HOME}/hk-parking-backups"
mkdir -p "$BACKUP_DIR"

mysql_do() { mysql -u"$DBUSER" -p"$DBPASS" "$DB" "$@"; }

echo "== HK-PARKING migration =="
echo "-- parked cars in legacy player_parking:"
mysql_do -N -e "SELECT COUNT(*) FROM player_parking;"
echo "-- rows that will be migrated (join match, valid coords):"
mysql_do -N -e "SELECT COUNT(*) FROM player_vehicles pv JOIN player_parking pp ON pp.plate COLLATE utf8mb4_general_ci = pv.plate WHERE JSON_VALID(pp.coords)=1;"

if [[ "${1:-}" == "--dry" ]]; then
    echo "-- DRY RUN, no changes made."
    exit 0
fi

echo "-- backing up player_vehicles + player_parking to ${BACKUP_DIR} ..."
mysqldump -u"$DBUSER" -p"$DBPASS" "$DB" player_vehicles player_parking player_parking_vips \
    > "${BACKUP_DIR}/parking_backup_${STAMP}.sql"
echo "   backup: ${BACKUP_DIR}/parking_backup_${STAMP}.sql"

echo "-- applying hk_parking.sql ..."
mysql_do < "${HERE}/hk_parking.sql"

echo "== done. Rollback if needed:  mysql -u$DBUSER -p $DB < ${BACKUP_DIR}/parking_backup_${STAMP}.sql"
