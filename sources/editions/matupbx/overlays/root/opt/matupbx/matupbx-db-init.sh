#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# First-boot fallback: the ISO build bakes the schema into the image, so this
# only does work if the database is missing or empty (e.g. the user wiped
# /var/lib/mysql, or a build skipped the bake step).
set -euo pipefail

APP=/var/www/html/matupbx
DBDIR=$APP/install/database
SOCKET=/run/mysqld/mysqld.sock

tables=$(mysql --socket="$SOCKET" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='snep'" 2>/dev/null || echo 0)
if [[ "$tables" -gt 0 ]]; then
    exit 0
fi

mysql --socket="$SOCKET" < "$DBDIR/database.sql"
mysql --socket="$SOCKET" snep < "$DBDIR/schema.sql"
mysql --socket="$SOCKET" snep < "$DBDIR/system_data.sql"
mysql --socket="$SOCKET" snep < "$DBDIR/core-cnl.sql"
if [[ -f $APP/modules/billing/install/schema.sql ]]; then
    mysql --socket="$SOCKET" snep < "$APP/modules/billing/install/schema.sql"
fi
if [[ -f $APP/modules/loguser/install/schema.sql ]]; then
    mysql --socket="$SOCKET" snep < "$APP/modules/loguser/install/schema.sql"
fi
echo "[matupbx-init] database imported"
