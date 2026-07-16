#!/bin/bash
# install.sh — install/update the Migrate Authentik module into a running
# infra-TAK console.
#
# What it does:
#   1. Makes sure this repo lives at a canonical checkout (~/.infra-tak-modules/
#      migrate-authentik) so the console's "Download changes" button always
#      knows where to `git pull`.
#   2. Copies migrate_authentik.py + the migration scripts into the infra-TAK
#      install directory.
#   3. Patches app.py (idempotent — safe to re-run) to:
#        a. register the module's routes at startup, same convention as
#           esri.py's register_routes(app, login_required, load_settings, save_settings)
#        b. add a "Migrate" button next to "Update config" on the Authentik page
#   4. Restarts the takwerx-console systemd service so the button appears
#      immediately.
#
# Usage:
#   sudo bash install.sh            # first-time install (or full re-install)
#   sudo bash install.sh --sync     # re-apply only (used by the in-console
#                                    # "Download changes & apply" button after
#                                    # it has already git-pulled this repo)

set -euo pipefail

MODULE_CHECKOUT_DIR="${MODULE_CHECKOUT_DIR:-$HOME/.infra-tak-modules/migrate-authentik}"
MODULE_REPO_URL="${MODULE_REPO_URL:-https://github.com/jpat-12/InfraTAK-Module-MigrateAuthentik.git}"
CONSOLE_SERVICE="${CONSOLE_SERVICE:-takwerx-console}"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root (sudo bash $0 $*)" >&2
    exit 1
fi

# --- 1. Canonical checkout -----------------------------------------------
# Always tracks $MODULE_REPO_URL directly (never a local directory) so the
# in-console "Download changes" button reliably pulls from GitHub. If an
# earlier version of this script left the checkout pointed at a local path
# (e.g. wherever you first ran install.sh from), self-heal it here.
if [ -d "$MODULE_CHECKOUT_DIR/.git" ]; then
    CURRENT_ORIGIN="$(git -C "$MODULE_CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
    if [ "$CURRENT_ORIGIN" != "$MODULE_REPO_URL" ]; then
        echo "==> Module checkout's origin was '$CURRENT_ORIGIN' (not GitHub) — fixing..."
        git -C "$MODULE_CHECKOUT_DIR" remote set-url origin "$MODULE_REPO_URL"
    fi
    echo "==> Updating module checkout at $MODULE_CHECKOUT_DIR..."
    git -C "$MODULE_CHECKOUT_DIR" fetch origin
    git -C "$MODULE_CHECKOUT_DIR" reset --hard origin/master
else
    echo "==> No git checkout found — cloning $MODULE_REPO_URL into $MODULE_CHECKOUT_DIR..."
    mkdir -p "$(dirname "$MODULE_CHECKOUT_DIR")"
    git clone "$MODULE_REPO_URL" "$MODULE_CHECKOUT_DIR"
fi
SRC_DIR="$MODULE_CHECKOUT_DIR"

# --- 2. Locate the infra-TAK install (same search as authentik-repoint-caddy.sh) ---
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

# --- 3. Sync module files into the console ------------------------------
cp -f "$SRC_DIR/migrate_authentik.py" "$CONSOLE_DIR/migrate_authentik.py"
mkdir -p "$CONSOLE_DIR/scripts/authentik-migrate"
cp -f "$SRC_DIR/scripts/"*.sh "$CONSOLE_DIR/scripts/authentik-migrate/"
chmod +x "$CONSOLE_DIR/scripts/authentik-migrate/"*.sh
MODULE_VERSION="$(grep -m1 '^MODULE_VERSION' "$CONSOLE_DIR/migrate_authentik.py" | sed -E "s/.*= *'([^']+)'.*/\1/")"
echo "==> Synced migrate_authentik.py (v${MODULE_VERSION:-unknown}) + scripts/authentik-migrate/*.sh"

# --- 4. Patch app.py (idempotent) ---------------------------------------
python3 - "$CONSOLE_DIR/app.py" <<'PYEOF'
import re, sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    src = f.read()

MARKER = '[migrate_authentik] Failed to register'
if MARKER not in src:
    anchor = "print(f'[esri] Failed to register Esri CoT Bridge module: {_e}', flush=True)\n"
    if anchor not in src:
        print("ERROR: could not find esri registration anchor in app.py — module registration NOT applied", file=sys.stderr)
        sys.exit(1)
    block = (
        "\ntry:\n"
        "    import migrate_authentik as _migrate_authentik_module\n"
        "    _migrate_authentik_module.register_routes(app, login_required, load_settings, save_settings, _ssh_probe, _get_module_deployment_config)\n"
        "except Exception as _e:\n"
        "    print(f'[migrate_authentik] Failed to register Migrate Authentik module: {_e}', flush=True)\n"
    )
    src = src.replace(anchor, anchor + block, 1)
    print("    + registered migrate_authentik.register_routes()")
else:
    print("    = module registration already present")

BTN = '<button class="control-btn" onclick="window.location.href=\'/authentik/migrate\'">🔁 Migrate</button>'
OLD = '<button class="control-btn" onclick="reconfigureAk()">🔄 Update config</button>'
if BTN not in src:
    n = src.count(OLD)
    if n == 0:
        print("ERROR: could not find 'Update config' button anchor in AUTHENTIK_TEMPLATE — button NOT injected", file=sys.stderr)
        sys.exit(1)
    src = src.replace(OLD, OLD + BTN)
    print(f"    + injected Migrate button ({n} occurrence(s))")
else:
    print("    = Migrate button already present")

with open(path, 'w', encoding='utf-8') as f:
    f.write(src)
PYEOF

# --- 5. Restart the console service --------------------------------------
if systemctl restart "$CONSOLE_SERVICE" 2>/dev/null; then
    echo "==> Restarted $CONSOLE_SERVICE"
else
    echo "    ⚠ Could not restart $CONSOLE_SERVICE via systemctl — restart it manually" >&2
fi

echo ""
echo "✓ Migrate Authentik module installed. Open the Authentik page in the"
echo "  console and look for the '🔁 Migrate' button next to 'Update config'."
