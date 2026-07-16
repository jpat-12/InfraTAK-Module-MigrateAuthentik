#!/bin/bash
# authentik-restore.sh — restore an Authentik backup (made by authentik-backup.sh)
# onto a NEW machine. Run as root on the new machine.
#
# What it does:
#   1. Installs Docker if missing (Debian/Ubuntu via get.docker.com; RHEL family via dnf)
#   2. Unpacks the backup into ~/authentik (same path the infra-TAK console expects)
#   3. Starts ONLY postgresql + redis, waits for PostgreSQL to accept connections
#   4. Restores database.sql into the fresh database
#   5. Starts the full stack (server, worker, ldap) and waits for the API
#
# The docker-compose.yml from the backup pins the same AUTHENTIK_TAG and
# postgres image as the old machine, so versions match exactly. Upgrade
# Authentik later through the infra-TAK console, not during migration.
#
# Usage:
#   sudo bash authentik-restore.sh /root/authentik-backup-YYYYMMDD-HHMMSS.tar.gz [--force]
#   --force: overwrite an existing ~/authentik install (its containers are stopped
#            and its named volumes are REMOVED so the restored DB is authoritative)

set -euo pipefail

TARBALL="${1:-}"
FORCE="${2:-}"
AK_DIR="$HOME/authentik"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0 ...)" >&2
    exit 1
fi
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "Usage: sudo bash $0 /path/to/authentik-backup-*.tar.gz [--force]" >&2
    exit 1
fi

# --- 1. Docker ---
if ! command -v docker >/dev/null 2>&1; then
    echo "==> Docker not found — installing..."
    if command -v dnf >/dev/null 2>&1; then
        dnf -y install dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || \
            dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
    else
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
    fi
fi
docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose plugin missing" >&2; exit 1; }
echo "==> $(docker --version)"

# --- 2. Unpack ---
if [ -f "$AK_DIR/docker-compose.yml" ]; then
    if [ "$FORCE" != "--force" ]; then
        echo "ERROR: $AK_DIR already exists. Re-run with --force to replace it" >&2
        echo "       (this stops its containers and DELETES its database volumes)." >&2
        exit 1
    fi
    echo "==> --force: stopping existing stack and removing its volumes..."
    (cd "$AK_DIR" && docker compose down -v) || true
    mv "$AK_DIR" "${AK_DIR}.replaced-$(date +%Y%m%d-%H%M%S)"
fi

echo "==> Unpacking backup..."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -C "$WORK" -xzpf "$TARBALL"
SRC="$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -f "$SRC/.env" ] && [ -f "$SRC/docker-compose.yml" ] && [ -f "$SRC/database.sql" ] || {
    echo "ERROR: backup is missing .env, docker-compose.yml, or database.sql" >&2; exit 1; }

if [ -f "$SRC/manifest.txt" ]; then
    echo "==> Backup manifest:"
    sed 's/^/    /' "$SRC/manifest.txt"
    WANT_SHA="$(grep -m1 '^database_sha256:' "$SRC/manifest.txt" | awk '{print $2}' || true)"
    if [ -n "$WANT_SHA" ]; then
        HAVE_SHA="$(sha256sum "$SRC/database.sql" | cut -d' ' -f1)"
        if [ "$WANT_SHA" != "$HAVE_SHA" ]; then
            echo "ERROR: database.sql checksum mismatch — backup corrupted in transfer" >&2
            exit 1
        fi
        echo "    ✓ database.sql checksum verified"
    fi
fi

mkdir -p "$AK_DIR"
cp -a "$SRC/.env" "$AK_DIR/.env"
cp -a "$SRC/docker-compose.yml" "$AK_DIR/docker-compose.yml"
for sub in blueprints media certs custom-templates; do
    [ -d "$SRC/$sub" ] && cp -a "$SRC/$sub" "$AK_DIR/$sub"
done
chmod 600 "$AK_DIR/.env"
echo "==> Files restored to $AK_DIR"

PG_USER="$(grep -m1 '^PG_USER=' "$AK_DIR/.env" | cut -d= -f2- || true)"
PG_DB="$(grep -m1 '^PG_DB=' "$AK_DIR/.env" | cut -d= -f2- || true)"
PG_USER="${PG_USER:-authentik}"
PG_DB="${PG_DB:-authentik}"

# --- 3. Database first: start only postgresql + redis so server/worker don't
#        run migrations against an empty DB before the restore lands.
echo "==> Starting postgresql + redis..."
cd "$AK_DIR"
docker compose up -d postgresql redis

echo "==> Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 60); do
    if docker compose exec -T postgresql pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        break
    fi
    [ "$i" -eq 60 ] && { echo "ERROR: PostgreSQL did not become ready in 120s" >&2; exit 1; }
    sleep 2
done
echo "    ✓ PostgreSQL ready"

# --- 4. Restore ---
echo "==> Restoring database (this can take a few minutes)..."
docker compose exec -T postgresql psql -U "$PG_USER" -d "$PG_DB" -q -v ON_ERROR_STOP=0 < "$SRC/database.sql" > /dev/null
TABLES="$(docker compose exec -T postgresql psql -U "$PG_USER" -d "$PG_DB" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
if [ "${TABLES:-0}" -lt 50 ]; then
    echo "ERROR: only $TABLES tables after restore — something went wrong" >&2
    exit 1
fi
echo "    ✓ Database restored ($TABLES tables)"

# --- 5. Full stack ---
echo "==> Starting full Authentik stack..."
docker compose up -d

echo "==> Waiting for Authentik API (first start pulls images + warms up; up to ~5 min)..."
AK_TOKEN="$(grep -m1 '^AUTHENTIK_TOKEN=' "$AK_DIR/.env" | cut -d= -f2- || true)"
[ -z "$AK_TOKEN" ] && AK_TOKEN="$(grep -m1 '^AUTHENTIK_BOOTSTRAP_TOKEN=' "$AK_DIR/.env" | cut -d= -f2- || true)"
API_OK=""
for i in $(seq 1 100); do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $AK_TOKEN" http://127.0.0.1:9090/api/v3/admin/version/ 2>/dev/null || true)"
    if [ "$CODE" = "200" ]; then API_OK=1; break; fi
    sleep 3
done
if [ -n "$API_OK" ]; then
    echo "    ✓ Authentik API is up and the bootstrap token works"
else
    echo "    ⚠ API not confirmed yet — check: cd $AK_DIR && docker compose logs -f server"
fi

# --- 6. Pick the IP the console/Caddy should use to reach this machine ---
CHOSEN_IP=""
mapfile -t LOCAL_IPS < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u)
PUBLIC_IP="$(curl -4 -s -m 5 https://ifconfig.me 2>/dev/null || true)"
CANDIDATES=("${LOCAL_IPS[@]}")
if [ -n "$PUBLIC_IP" ] && ! printf '%s\n' "${LOCAL_IPS[@]}" | grep -qx "$PUBLIC_IP"; then
    CANDIDATES+=("$PUBLIC_IP (public, NATed)")
fi

echo ""
if [ -t 0 ] && [ "${#CANDIDATES[@]}" -gt 0 ]; then
    echo "==> This machine's IP addresses — which one should the infra-TAK console"
    echo "    and Caddy use to reach Authentik (port 9090)?"
    echo ""
    i=1
    for c in "${CANDIDATES[@]}"; do
        echo "      $i) $c"
        i=$((i+1))
    done
    echo "      $i) other (enter manually)"
    echo ""
    while [ -z "$CHOSEN_IP" ]; do
        read -r -p "    Select [1-$i]: " PICK
        if [ "$PICK" = "$i" ]; then
            read -r -p "    Enter IP: " CHOSEN_IP
        elif [[ "$PICK" =~ ^[0-9]+$ ]] && [ "$PICK" -ge 1 ] && [ "$PICK" -lt "$i" ]; then
            CHOSEN_IP="$(echo "${CANDIDATES[$((PICK-1))]}" | awk '{print $1}')"
        fi
        [[ "$CHOSEN_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "    Invalid IP."; CHOSEN_IP=""; }
    done
    echo "$CHOSEN_IP" > "$AK_DIR/.migration-chosen-ip"
    echo "    ✓ Selected $CHOSEN_IP (saved to $AK_DIR/.migration-chosen-ip)"
else
    echo "==> Non-interactive shell or no IPs detected — skipping IP selection."
    echo "    This machine's IPs: ${CANDIDATES[*]:-unknown}"
fi

echo ""
echo "✓ Restore complete. Remaining steps (see README.md in this folder):"
if [ -n "$CHOSEN_IP" ]; then
    echo "   1. On the infra-TAK CONSOLE host, repoint Caddy + console settings:"
    echo "        sudo bash authentik-repoint-caddy.sh $CHOSEN_IP"
else
    echo "   1. On the infra-TAK CONSOLE host, repoint Caddy + console settings:"
    echo "        sudo bash authentik-repoint-caddy.sh <this machine's IP>"
fi
echo "      (If Authentik and the console live on the SAME machine, pass 127.0.0.1.)"
echo "   2. Point DNS / firewall at this machine (console host → here on 9090;"
echo "      389/636 stay loopback-only unless TAK Server is on another host)."
echo "   3. In the console, run 'Update Config & Reconnect' on the Authentik page"
echo "      (rewires forward auth, LDAP token, CoreConfig)."
echo "   4. If TAK Server uses this Authentik for LDAP: run 'Fix LDAP Token' if the"
echo "      ldap container shows unhealthy, then 'Connect TAK Server to LDAP' if needed."
echo "   5. Verify: log into Authentik, log into TAK Portal, test an ATAK/8446 login."
echo "   6. Once verified, decommission the old machine (or 'docker compose down' there"
echo "      first, BEFORE go-live, if both must briefly coexist)."
