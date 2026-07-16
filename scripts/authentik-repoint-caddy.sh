#!/bin/bash
# authentik-repoint-caddy.sh — point the infra-TAK console and Caddy at the
# Authentik instance on its NEW machine. Run as root on the CONSOLE host
# (the machine running Caddy and the infra-TAK web console).
#
# What it does:
#   1. Detects the console install and reads the current Authentik upstream
#   2. Prompts for / accepts the new machine's IP and probes port 9090
#   3. Updates .config/settings.json (authentik_deployment target) — required,
#      or the console would regenerate the Caddyfile with the OLD address
#   4. Rewrites /etc/caddy/Caddyfile upstreams (<old>:9090 → <new>:9090),
#      validates, and reloads Caddy (rolls back the file if validation fails)
#
# Usage:
#   sudo bash authentik-repoint-caddy.sh [NEW_IP]
#   Pass 127.0.0.1 if Authentik now runs on this same machine (local mode).

set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
NEW_IP="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0 ...)" >&2
    exit 1
fi

# --- 1. Locate the console install (app.py + .config/settings.json) ---
CONSOLE_DIR=""
for d in /opt/infra-TAK /opt/infra-tak /root/infra-TAK /root/infra-tak "$HOME/infra-TAK" "$HOME/infra-tak"; do
    if [ -f "$d/app.py" ] && [ -f "$d/.config/settings.json" ]; then
        CONSOLE_DIR="$d"; break
    fi
done
if [ -z "$CONSOLE_DIR" ]; then
    CONSOLE_DIR="$(find /root /home /opt -maxdepth 3 -name app.py -path '*infra*' 2>/dev/null \
        | while read -r f; do d="$(dirname "$f")"; [ -f "$d/.config/settings.json" ] && echo "$d" && break; done || true)"
fi
if [ -z "$CONSOLE_DIR" ]; then
    echo "ERROR: infra-TAK console install not found on this machine." >&2
    echo "       This script must run on the CONSOLE host (where Caddy runs)." >&2
    exit 1
fi
SETTINGS="$CONSOLE_DIR/.config/settings.json"
echo "==> Console: $CONSOLE_DIR"

OLD_UP="$(python3 - "$SETTINGS" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
cfg = s.get('authentik_deployment') or {}
host = ((cfg.get('remote') or {}).get('host') or '').strip()
print(f'{host}:9090' if cfg.get('target_mode') == 'remote' and host else '127.0.0.1:9090')
EOF
)"
echo "==> Current Authentik upstream: $OLD_UP"

# --- 2. New IP: from arg or prompt; probe it ---
if [ -z "$NEW_IP" ]; then
    if [ ! -t 0 ]; then
        echo "ERROR: no IP argument and no interactive terminal. Usage: $0 NEW_IP" >&2
        exit 1
    fi
    echo ""
    echo "    Enter the IP of the machine now hosting Authentik."
    echo "    (authentik-restore.sh printed the chosen IP; it is also saved on that"
    echo "     machine in ~/authentik/.migration-chosen-ip. Use 127.0.0.1 if Authentik"
    echo "     runs on THIS machine.)"
    read -r -p "    New Authentik IP: " NEW_IP
fi
[[ "$NEW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: '$NEW_IP' is not a valid IPv4 address" >&2; exit 1; }

# Local mode if the IP is loopback or one of this machine's own addresses
TARGET_MODE=remote
if [ "$NEW_IP" = "127.0.0.1" ] || ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$NEW_IP"; then
    TARGET_MODE=local
    NEW_UP="127.0.0.1:9090"
else
    NEW_UP="$NEW_IP:9090"
fi
echo "==> New upstream: $NEW_UP (target mode: $TARGET_MODE)"

echo "==> Probing http://$NEW_UP ..."
CODE="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$NEW_UP/api/v3/root/config/" 2>/dev/null || true)"
if [ "$CODE" = "000" ] || [ -z "$CODE" ]; then
    echo "    ⚠ No response from $NEW_UP — Authentik may still be starting, or a"
    echo "      firewall is blocking 9090 from this host."
    if [ -t 0 ]; then
        read -r -p "    Continue anyway? [y/N]: " GO
        [ "$GO" = "y" ] || [ "$GO" = "Y" ] || { echo "Aborted — nothing changed."; exit 1; }
    else
        echo "    Continuing (non-interactive)."
    fi
else
    echo "    ✓ Authentik answered (HTTP $CODE)"
fi

# --- 3. settings.json (source of truth — console regenerates Caddyfile from it) ---
cp -a "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
python3 - "$SETTINGS" "$TARGET_MODE" "$NEW_IP" <<'EOF'
import json, sys
path, mode, ip = sys.argv[1], sys.argv[2], sys.argv[3]
s = json.load(open(path))
cfg = s.get('authentik_deployment') or {}
cfg['target_mode'] = mode
if mode == 'remote':
    remote = cfg.get('remote') or {}
    remote['host'] = ip
    cfg['remote'] = remote
    cfg['deployed'] = True
s['authentik_deployment'] = cfg
json.dump(s, open(path, 'w'), indent=2)
print(f"    ✓ settings.json: authentik_deployment -> {mode}" + (f" @ {ip}" if mode == 'remote' else ""))
EOF

# --- 4. Caddyfile: swap upstream, validate, reload ---
if [ ! -f "$CADDYFILE" ]; then
    echo "==> No $CADDYFILE — Caddy not deployed yet; settings updated, done."
    echo "    Deploy/configure Caddy from the console and it will use the new upstream."
    exit 0
fi
if [ "$OLD_UP" = "$NEW_UP" ]; then
    echo "==> Caddyfile upstream unchanged ($NEW_UP) — no rewrite needed."
else
    CADDY_BAK="$CADDYFILE.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$CADDYFILE" "$CADDY_BAK"
    # Port 9090 is only ever the Authentik upstream in infra-TAK Caddyfiles,
    # so a plain string swap is safe and catches every vhost that proxies it.
    sed -i "s|$OLD_UP|$NEW_UP|g" "$CADDYFILE"
    N="$(grep -c "$NEW_UP" "$CADDYFILE" || true)"
    echo "==> Caddyfile: $OLD_UP → $NEW_UP ($N reference(s); backup: $CADDY_BAK)"

    if command -v caddy >/dev/null 2>&1; then
        if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
            echo "ERROR: caddy validate failed — restoring previous Caddyfile" >&2
            cp -a "$CADDY_BAK" "$CADDYFILE"
            exit 1
        fi
        echo "    ✓ Caddyfile validates"
    fi
fi

if systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null; then
    echo "    ✓ Caddy reloaded"
else
    echo "    ⚠ Could not reload Caddy via systemctl — reload it manually" >&2
fi

echo ""
echo "✓ Console and Caddy now point at $NEW_UP."
echo ""
echo "  Finish up in the console (https://infratak.<fqdn> or https://<console-ip>:5001):"
echo "   - Authentik page → 'Update Config & Reconnect'  (forward auth, outpost, CoreConfig)"
echo "   - If the ldap container is unhealthy → 'Fix LDAP Token'"
echo "   - Then verify TAK Portal and an ATAK/8446 login."
