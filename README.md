# InfraTAK-Module-MigrateAuthentik

Adds a **"🔁 Migrate"** button to the Authentik page of an
[infra-TAK](https://github.com/jpat-12/infra-TAK) console. It moves an
Authentik deployment to a different machine — backup, copy, restore,
cutover — from the console UI instead of SSHing in and running scripts by
hand, and can pull its own updates into a running console with one click.

Under the hood this wraps the same toolkit as infra-TAK's
`scripts/authentik-migrate/` (backup / restore / repoint-caddy) — nothing
here reinvents the migration itself, it just gives it a face and wires it
into the console process.

## What it does

| Wizard step | Runs on | Script |
|---|---|---|
| Backup source | wherever Authentik lives today (local console box, or the console's configured remote) | `authentik-backup.sh` |
| Copy + restore on target | the new machine, over SSH with credentials you enter in the wizard | `authentik-restore.sh` |
| Repoint console + Caddy | this console host | `authentik-repoint-caddy.sh` |

Live output from each step streams into a log panel in the browser, the same
way infra-TAK streams deploy logs elsewhere in the console.

**Not automated (do these manually, same as the plain-script workflow):**
stopping the old machine before cutover, DNS/firewall changes, "Update
Config & Reconnect" on the Authentik page after repointing, and
decommissioning the old box. See infra-TAK's
`scripts/authentik-migrate/README.md` for the full manual walkthrough this
module is built on.

## Install

On the infra-TAK console host, as root:

```bash
git clone https://github.com/jpat-12/InfraTAK-Module-MigrateAuthentik.git
cd InfraTAK-Module-MigrateAuthentik
sudo bash install.sh
```

This:
1. Copies itself to a canonical checkout at `~/.infra-tak-modules/migrate-authentik`
   (so the in-console update button always knows where to `git pull` from).
2. Copies `migrate_authentik.py` and `scripts/authentik-migrate/*.sh` into the
   detected infra-TAK install directory.
3. Patches `app.py` (idempotently — safe to re-run) to register the module's
   routes at startup and add the "🔁 Migrate" button next to "Update config"
   on the Authentik page, following the same `register_routes(app,
   login_required, load_settings, save_settings)` convention infra-TAK
   already uses for `esri.py`.
4. Restarts `takwerx-console` so the button shows up immediately.

## Updating

From the Authentik page, click **🔁 Migrate → Download changes & apply** at
the bottom of the wizard. That does exactly what running `install.sh --sync`
by hand would do: `git pull` the module's checkout, re-sync the files into
the console, re-patch `app.py` if needed, and restart the console service.
The page will go blank for a few seconds while the console restarts, then
reload itself.

To update from the command line instead:

```bash
sudo bash ~/.infra-tak-modules/migrate-authentik/install.sh
```

## Uninstall

From the wizard page (`/authentik/migrate`), scroll to **Remove module** and
click **Uninstall module**. It removes the button and this module's routes
from `app.py`, deletes `migrate_authentik.py` from the console, and restarts
`takwerx-console` — same as running `uninstall.sh` by hand:

```bash
sudo bash ~/.infra-tak-modules/migrate-authentik/uninstall.sh
```

Uninstalling does **not** touch `scripts/authentik-migrate/*.sh` (that's
infra-TAK's own migration toolkit, not owned by this module) and does not
undo anything a migration you already ran did — it only removes the
console integration. Safe to run even if the module isn't installed.

## Using the wizard

1. **Target machine** — enter the new box's host/IP and SSH credentials
   (key or password), then **Test SSH**.
2. **Backup source** — click **Run backup**. No downtime on the source; it's
   a live `pg_dump`. Avoid making admin changes in Authentik between this
   step and cutover.
3. **Restore on target** — copies the tarball + installs Docker if needed,
   restores the database before Authentik ever starts against it, brings the
   stack up. The log panel reports the candidate IPs the new machine
   detected for itself.
4. **Repoint console + Caddy** — enter the IP from step 3 (or `127.0.0.1` if
   the target IS this console) and click **Repoint now**. This updates
   `.config/settings.json`'s `authentik_deployment` and rewrites the Caddy
   upstream.
5. Finish the cutover manually: stop the old machine, verify DNS/firewall,
   run **Update Config & Reconnect** on the Authentik page, verify logins,
   then decommission the old box.

## Files

- `migrate_authentik.py` — Flask routes + wizard page, registered into
  infra-TAK's `app.py` at startup.
- `scripts/authentik-backup.sh`, `authentik-restore.sh`,
  `authentik-repoint-caddy.sh` — the migration toolkit these routes wrap
  (also runnable standalone, same as in infra-TAK proper).
- `install.sh` — install/update entry point (see above).
- `uninstall.sh` — removes the module's console integration (see above).
