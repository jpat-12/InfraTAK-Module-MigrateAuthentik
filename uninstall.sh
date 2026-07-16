#!/bin/bash
# uninstall.sh — remove the Migrate Authentik module from an infra-TAK console.
#
# Reverses exactly what install.sh applied:
#   1. Removes the migrate_authentik.register_routes() block from app.py
#   2. Removes the "🔁 Migrate" button from the Authentik page template
#   3. Deletes migrate_authentik.py from the console install
#   4. Restarts takwerx-console so the removal takes effect immediately
#
# Does NOT touch scripts/authentik-migrate/*.sh — those are infra-TAK's own
# migration toolkit (pre-dates this module) and are shared by both. Does NOT
# touch .config/settings.json's authentik_migration key (harmless orphaned
# state — target host/backup path — left in place in case you reinstall).
#
# Safe to run even if the module was never installed (no-ops cleanly).
#
# Usage:
#   sudo bash uninstall.sh

set -euo pipefail

CONSOLE_SERVICE="${CONSOLE_SERVICE:-takwerx-console}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0)" >&2
    exit 1
fi

CONSOLE_DIR=""
for d in /opt/infra-TAK /opt/infra-tak /root/infra-TAK /root/infra-tak "$HOME/infra-TAK" "$HOME/infra-tak"; do
    if [ -f "$d/app.py" ]; then
        CONSOLE_DIR="$d"; break
    fi
done
if [ -z "$CONSOLE_DIR" ]; then
    CONSOLE_DIR="$(find /root /home /opt -maxdepth 3 -name app.py -path '*infra*' 2>/dev/null | head -1 | xargs -r dirname || true)"
fi
if [ -z "$CONSOLE_DIR" ]; then
    echo "ERROR: could not find an infra-TAK install (looked for app.py under /opt, /root, \$HOME)." >&2
    exit 1
fi
echo "==> infra-TAK console: $CONSOLE_DIR"

python3 - "$CONSOLE_DIR/app.py" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

REG_BLOCK = (
    "\ntry:\n"
    "    import migrate_authentik as _migrate_authentik_module\n"
    "    _migrate_authentik_module.register_routes(app, login_required, load_settings, save_settings, _ssh_probe, _get_module_deployment_config)\n"
    "except Exception as _e:\n"
    "    print(f'[migrate_authentik] Failed to register Migrate Authentik module: {_e}', flush=True)\n"
)
if REG_BLOCK in src:
    src = src.replace(REG_BLOCK, '', 1)
    print("    - removed module registration")
else:
    print("    = module registration not present, nothing to remove")

BTN = '<button class="control-btn" onclick="window.location.href=\'/authentik/migrate\'">🔁 Migrate</button>'
n = src.count(BTN)
if n:
    src = src.replace(BTN, '')
    print(f"    - removed Migrate button ({n} occurrence(s))")
else:
    print("    = Migrate button not present, nothing to remove")

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)
PYEOF

if [ -f "$CONSOLE_DIR/migrate_authentik.py" ]; then
    rm -f "$CONSOLE_DIR/migrate_authentik.py"
    echo "    - deleted migrate_authentik.py"
else
    echo "    = migrate_authentik.py not present, nothing to delete"
fi

if systemctl restart "$CONSOLE_SERVICE" 2>/dev/null; then
    echo "==> Restarted $CONSOLE_SERVICE"
else
    echo "    ⚠ Could not restart $CONSOLE_SERVICE via systemctl — restart it manually" >&2
fi

echo ""
echo "✓ Migrate Authentik module uninstalled. scripts/authentik-migrate/*.sh"
echo "  were left in place (they belong to infra-TAK's own migration toolkit,"
echo "  not this module) — remove them by hand if you want them gone too."
