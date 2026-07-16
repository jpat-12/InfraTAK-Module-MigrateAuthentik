#!/bin/bash
# authentik-backup.sh — create a portable backup of the infra-TAK Authentik deployment.
# Run on the OLD machine (the one currently hosting Authentik) as root.
#
# Produces a single tarball containing:
#   - .env                    (all secrets: PG_PASS, secret key, bootstrap token, LDAP service password)
#   - docker-compose.yml      (infra-TAK patches + injected LDAP outpost token + pinned AUTHENTIK_TAG)
#   - blueprints/             (tak-ldap-setup.yaml and any custom blueprints)
#   - media/, certs/, custom-templates/  (branding, uploaded assets)
#   - database.sql            (pg_dump of the Authentik PostgreSQL database)
#   - manifest.txt            (versions + checksums for sanity checks on restore)
#
# The database dump is taken live with pg_dump (transactionally consistent) —
# no downtime on the old machine. Redis is NOT backed up: it only holds
# sessions and task queue state; users simply log in again after migration.
#
# Usage:
#   sudo bash authentik-backup.sh [output-dir]
#   (default output dir: /root)

set -euo pipefail

OUT_DIR="${1:-/root}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_NAME="authentik-backup-${STAMP}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0)" >&2
    exit 1
fi

# Locate the Authentik install dir the same way the console does
AK_DIR=""
for d in "$HOME/authentik" /root/authentik /opt/authentik; do
    if [ -f "$d/docker-compose.yml" ] && [ -f "$d/.env" ]; then
        AK_DIR="$d"
        break
    fi
done
if [ -z "$AK_DIR" ]; then
    echo "ERROR: Authentik install not found (looked for docker-compose.yml + .env in ~/authentik, /opt/authentik)" >&2
    exit 1
fi
echo "==> Authentik install: $AK_DIR"

PG_USER="$(grep -m1 '^PG_USER=' "$AK_DIR/.env" | cut -d= -f2- || true)"
PG_DB="$(grep -m1 '^PG_DB=' "$AK_DIR/.env" | cut -d= -f2- || true)"
PG_USER="${PG_USER:-authentik}"
PG_DB="${PG_DB:-authentik}"

# Verify the postgresql container is up
if ! (cd "$AK_DIR" && docker compose ps --status running postgresql 2>/dev/null | grep -q postgresql); then
    echo "ERROR: postgresql container is not running. Start the stack first:" >&2
    echo "  cd $AK_DIR && docker compose up -d" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$BACKUP_NAME"
mkdir -p "$STAGE"

echo "==> Dumping PostgreSQL database ($PG_DB as $PG_USER)..."
(cd "$AK_DIR" && docker compose exec -T postgresql pg_dump -U "$PG_USER" -d "$PG_DB" --clean --if-exists) > "$STAGE/database.sql"
DUMP_LINES=$(wc -l < "$STAGE/database.sql")
if [ "$DUMP_LINES" -lt 100 ]; then
    echo "ERROR: database dump looks empty ($DUMP_LINES lines) — aborting" >&2
    exit 1
fi
echo "    ✓ database.sql ($(du -h "$STAGE/database.sql" | cut -f1), $DUMP_LINES lines)"

echo "==> Copying configuration and assets..."
cp -a "$AK_DIR/.env" "$STAGE/.env"
cp -a "$AK_DIR/docker-compose.yml" "$STAGE/docker-compose.yml"
for sub in blueprints media certs custom-templates; do
    if [ -d "$AK_DIR/$sub" ]; then
        cp -a "$AK_DIR/$sub" "$STAGE/$sub"
        echo "    ✓ $sub/"
    fi
done

echo "==> Writing manifest..."
{
    echo "backup_created: $(date -Is)"
    echo "source_host: $(hostname -f 2>/dev/null || hostname)"
    echo "source_dir: $AK_DIR"
    echo "authentik_tag: $(grep -m1 'AUTHENTIK_TAG' "$AK_DIR/docker-compose.yml" | sed 's/^[[:space:]]*//' || echo unknown)"
    echo "postgres_image: $(grep -m1 'image:.*postgres' "$AK_DIR/docker-compose.yml" | sed 's/^[[:space:]]*//' || echo unknown)"
    echo "database_sha256: $(sha256sum "$STAGE/database.sql" | cut -d' ' -f1)"
    echo "docker_version: $(docker --version 2>/dev/null || echo unknown)"
} > "$STAGE/manifest.txt"
cat "$STAGE/manifest.txt" | sed 's/^/    /'

echo "==> Creating tarball..."
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$BACKUP_NAME.tar.gz"
tar -C "$WORK" -czpf "$TARBALL" "$BACKUP_NAME"
chmod 600 "$TARBALL"

echo ""
echo "✓ Backup complete: $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo ""
echo "  This file contains ALL Authentik secrets — treat it like a password."
echo ""
echo "  Next: copy it to the new machine, e.g.:"
echo "    scp $TARBALL root@NEW_MACHINE_IP:/root/"
echo "  Then on the new machine:"
echo "    sudo bash authentik-restore.sh /root/$BACKUP_NAME.tar.gz"
