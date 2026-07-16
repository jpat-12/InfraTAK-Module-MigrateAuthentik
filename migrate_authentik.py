"""
migrate_authentik.py — Migrate Authentik module for infra-TAK

Registers /authentik/migrate and /api/authentik/migrate/* routes directly on
the Flask app, following the same convention as esri.py (register_routes
called once from app.py at startup).

What it does:
  - Wraps the scripts/authentik-migrate/*.sh toolkit (backup / restore /
    repoint-caddy) behind a wizard page reachable from a "Migrate" button on
    the Authentik page.
  - Backs up Authentik wherever it currently lives — the "current machine",
    detected automatically from infra-TAK's existing Authentik deployment
    config (local or remote) — copies the tarball to a "new machine" you
    enter SSH details for in the wizard, restores it there, and repoints
    Caddy + console settings at that new machine.
  - Ships a self-update action that git-pulls this module's own source repo
    and re-syncs it into the running console (see install.sh), so the module
    can be updated from a button instead of SSHing in by hand.

Call register_routes(app, login_required, load_settings, save_settings,
                      ssh_probe, get_deploy_cfg) from app.py.
"""

import json
import os
import re
import subprocess
import threading
import time

MIGRATE_KEY = 'authentik_migration'
MODULE_REPO_URL = 'https://github.com/jpat-12/InfraTAK-Module-MigrateAuthentik.git'
MODULE_CHECKOUT_DIR = os.path.expanduser('~/.infra-tak-modules/migrate-authentik')
CONSOLE_SERVICE = 'takwerx-console'

CONFIG_DIR = os.environ.get('CONFIG_DIR') or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '.config'
)
WORK_DIR = os.path.join(CONFIG_DIR, 'authentik-migrate')
SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'scripts', 'authentik-migrate')

_IP_RE = re.compile(r'^\d{1,3}(\.\d{1,3}){3}$')

# In-memory state for the wizard's live log panel — mirrors the pattern used
# by authentik_deploy_log/authentik_deploy_status elsewhere in the console.
MIGRATE_LOG = []
MIGRATE_STATE = {'running': False, 'stage': None, 'complete': False, 'error': False}

SELF_UPDATE_LOG = []
SELF_UPDATE_STATE = {'running': False, 'complete': False, 'error': False, 'restarted': False}

UNINSTALL_LOG = []
UNINSTALL_STATE = {'running': False, 'complete': False, 'error': False, 'restarted': False}


def _mlog(msg):
    MIGRATE_LOG.append(f'[{time.strftime("%H:%M:%S")}] {msg}')


def _sulog(msg):
    SELF_UPDATE_LOG.append(f'[{time.strftime("%H:%M:%S")}] {msg}')


def _uilog(msg):
    UNINSTALL_LOG.append(f'[{time.strftime("%H:%M:%S")}] {msg}')


def _load_state(load_settings):
    s = load_settings()
    return s.get(MIGRATE_KEY) or {}


def _save_state(load_settings, save_settings, **updates):
    s = load_settings()
    cur = s.get(MIGRATE_KEY) or {}
    cur.update(updates)
    s[MIGRATE_KEY] = cur
    save_settings(s)
    return cur


def _run_local(cmd, timeout=120):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    return r.returncode == 0, ((r.stdout or '') + (r.stderr or ''))


def register_routes(app, login_required, load_settings, save_settings, ssh_probe, get_deploy_cfg):
    from flask import request, jsonify, render_template_string, send_file

    os.makedirs(WORK_DIR, exist_ok=True)

    def _new_machine_cfg():
        return _load_state(load_settings).get('new_machine', {}) or {}

    def _ssh_new_machine_ok(cfg):
        host = (cfg.get('host') or '').strip()
        return bool(host)

    def _scp_to_new_machine(cfg, local_path, remote_path):
        host = cfg['host']
        user = (cfg.get('ssh_user') or 'root').strip() or 'root'
        port = str(int(cfg.get('ssh_port') or 22))
        key_path = (cfg.get('ssh_key_path') or '').strip()
        scp_cmd = ['scp', '-P', port, '-o', 'StrictHostKeyChecking=accept-new']
        if key_path:
            scp_cmd.extend(['-i', os.path.expanduser(key_path)])
        scp_cmd.extend([local_path, f'{user}@{host}:{remote_path}'])
        env = os.environ.copy()
        if (cfg.get('auth_method') or 'ssh_key') == 'password' and cfg.get('ssh_password'):
            scp_cmd = ['sshpass', '-e'] + scp_cmd
            env['SSHPASS'] = cfg['ssh_password']
        r = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=600, env=env)
        return r.returncode == 0, ((r.stdout or '') + (r.stderr or ''))

    # ------------------------------------------------------------------
    # Page
    # ------------------------------------------------------------------
    @app.route('/authentik/migrate')
    @login_required
    def authentik_migrate_page():
        state = _load_state(load_settings)
        return render_template_string(
            MIGRATE_TEMPLATE,
            new_machine=state.get('new_machine', {}),
            last_backup=state.get('last_backup'),
            chosen_ip=state.get('chosen_ip'),
        )

    # ------------------------------------------------------------------
    # New machine SSH setup (the destination you're migrating Authentik to)
    # ------------------------------------------------------------------
    @app.route('/api/authentik/migrate/new-machine', methods=['POST'])
    @login_required
    def authentik_migrate_save_new_machine():
        data = request.get_json() or {}
        new_machine = {
            'host': (data.get('host') or '').strip(),
            'ssh_user': (data.get('ssh_user') or 'root').strip() or 'root',
            'ssh_port': int(data.get('ssh_port') or 22),
            'auth_method': (data.get('auth_method') or 'ssh_key').strip(),
            'ssh_key_path': (data.get('ssh_key_path') or '~/.ssh/id_ed25519').strip(),
            'ssh_password': data.get('ssh_password') or '',
        }
        _save_state(load_settings, save_settings, new_machine=new_machine)
        return jsonify({'success': True})

    @app.route('/api/authentik/migrate/new-machine/test-ssh', methods=['POST'])
    @login_required
    def authentik_migrate_test_new_machine_ssh():
        cfg = _new_machine_cfg()
        if not _ssh_new_machine_ok(cfg):
            return jsonify({'error': 'New machine host not configured'}), 400
        ok, out = ssh_probe(cfg, 'echo ok && uname -a', timeout=15)
        return jsonify({'success': ok, 'output': out})

    # ------------------------------------------------------------------
    # Step 1 — back up the current machine (wherever Authentik lives today)
    # ------------------------------------------------------------------
    def _run_backup():
        MIGRATE_STATE.update({'running': True, 'stage': 'backup', 'complete': False, 'error': False})
        MIGRATE_LOG.clear()
        try:
            settings = load_settings()
            current_cfg = get_deploy_cfg(settings, 'authentik_deployment')
            backup_script = os.path.join(SCRIPTS_DIR, 'authentik-backup.sh')
            if current_cfg.get('target_mode') == 'remote' and (current_cfg.get('remote', {}).get('host') or '').strip():
                current = current_cfg['remote']
                _mlog(f"Current machine is remote ({current.get('host')}) — copying backup script over...")
                ok, out = _scp_to_new_machine(current, backup_script, '/root/authentik-backup.sh')
                if not ok:
                    _mlog(f'ERROR: could not copy backup script to current machine: {out}')
                    MIGRATE_STATE.update({'running': False, 'error': True})
                    return
                _mlog('Running backup on the current machine (pg_dump, no downtime)...')
                ok, out = ssh_probe(current, 'bash /root/authentik-backup.sh /root', timeout=600)
                _mlog(out)
                if not ok:
                    MIGRATE_STATE.update({'running': False, 'error': True})
                    return
                m = re.search(r'Backup complete: (\S+\.tar\.gz)', out)
                if not m:
                    _mlog('ERROR: could not determine backup tarball path from script output')
                    MIGRATE_STATE.update({'running': False, 'error': True})
                    return
                remote_tarball = m.group(1)
                local_tarball = os.path.join(WORK_DIR, os.path.basename(remote_tarball))
                _mlog(f'Pulling {remote_tarball} back to console...')
                user = (current.get('ssh_user') or 'root').strip() or 'root'
                port = str(int(current.get('ssh_port') or 22))
                key_path = (current.get('ssh_key_path') or '').strip()
                scp_cmd = ['scp', '-P', port, '-o', 'StrictHostKeyChecking=accept-new']
                if key_path:
                    scp_cmd.extend(['-i', os.path.expanduser(key_path)])
                scp_cmd.extend([f'{user}@{current["host"]}:{remote_tarball}', local_tarball])
                env = os.environ.copy()
                if (current.get('auth_method') or 'ssh_key') == 'password' and current.get('ssh_password'):
                    scp_cmd = ['sshpass', '-e'] + scp_cmd
                    env['SSHPASS'] = current['ssh_password']
                r = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=600, env=env)
                if r.returncode != 0:
                    _mlog(f'ERROR: failed to pull tarball back: {r.stderr}')
                    MIGRATE_STATE.update({'running': False, 'error': True})
                    return
            else:
                _mlog('Current machine is this console — running backup locally (pg_dump, no downtime)...')
                ok, out = _run_local(f'bash "{backup_script}" "{WORK_DIR}"', timeout=600)
                _mlog(out)
                if not ok:
                    MIGRATE_STATE.update({'running': False, 'error': True})
                    return
                m = re.search(r'Backup complete: (\S+\.tar\.gz)', out)
                local_tarball = m.group(1) if m else None
                if not local_tarball or not os.path.exists(local_tarball):
                    _mlog('ERROR: could not determine backup tarball path from script output')
                    MIGRATE_STATE.update({'running': False, 'error': True})
                    return
            _mlog(f'Backup ready: {local_tarball}')
            _save_state(load_settings, save_settings, last_backup={
                'path': local_tarball, 'created': time.strftime('%Y-%m-%d %H:%M:%S'),
            })
            MIGRATE_STATE.update({'running': False, 'complete': True, 'stage': 'backup'})
        except Exception as e:
            _mlog(f'ERROR: {e}')
            MIGRATE_STATE.update({'running': False, 'error': True})

    @app.route('/api/authentik/migrate/backup', methods=['POST'])
    @login_required
    def authentik_migrate_backup():
        if MIGRATE_STATE.get('running'):
            return jsonify({'error': 'Migration step already in progress'}), 409
        threading.Thread(target=_run_backup, daemon=True).start()
        return jsonify({'success': True})

    @app.route('/api/authentik/migrate/backup/download')
    @login_required
    def authentik_migrate_backup_download():
        state = _load_state(load_settings)
        path = (state.get('last_backup') or {}).get('path')
        if not path or not os.path.exists(path):
            return jsonify({'error': 'No backup available'}), 404
        return send_file(path, as_attachment=True)

    # ------------------------------------------------------------------
    # Step 2 — copy + restore on the new machine
    # ------------------------------------------------------------------
    def _run_restore():
        MIGRATE_STATE.update({'running': True, 'stage': 'restore', 'complete': False, 'error': False})
        MIGRATE_LOG.clear()
        try:
            cfg = _new_machine_cfg()
            if not _ssh_new_machine_ok(cfg):
                _mlog('ERROR: new machine not configured — fill in step 1 first')
                MIGRATE_STATE.update({'running': False, 'error': True})
                return
            state = _load_state(load_settings)
            tarball = (state.get('last_backup') or {}).get('path')
            if not tarball or not os.path.exists(tarball):
                _mlog('ERROR: no backup on hand — run the backup step first')
                MIGRATE_STATE.update({'running': False, 'error': True})
                return
            restore_script = os.path.join(SCRIPTS_DIR, 'authentik-restore.sh')
            remote_tarball = f'/root/{os.path.basename(tarball)}'
            _mlog(f'Copying backup + restore script to {cfg["host"]}...')
            ok, out = _scp_to_new_machine(cfg, tarball, remote_tarball)
            if not ok:
                _mlog(f'ERROR copying tarball: {out}')
                MIGRATE_STATE.update({'running': False, 'error': True})
                return
            ok, out = _scp_to_new_machine(cfg, restore_script, '/root/authentik-restore.sh')
            if not ok:
                _mlog(f'ERROR copying restore script: {out}')
                MIGRATE_STATE.update({'running': False, 'error': True})
                return
            _mlog('Running restore on the new machine (Docker install if needed, DB restore, stack up)...')
            ok, out = ssh_probe(cfg, f'bash /root/authentik-restore.sh {remote_tarball}', timeout=900)
            _mlog(out)
            if not ok:
                MIGRATE_STATE.update({'running': False, 'error': True})
                return
            ips = re.findall(r'^\s*\d+\)\s+([0-9.]+)', out, re.MULTILINE)
            if not ips:
                m = re.search(r"This machine's IPs:\s*(.+)", out)
                if m:
                    ips = [t.split()[0] for t in m.group(1).split() if _IP_RE.match(t.split()[0])]
            _mlog(f'Candidate IPs for the next step (point console + Caddy): {ips or "none detected — enter manually"}')
            _save_state(load_settings, save_settings, candidate_ips=ips)
            MIGRATE_STATE.update({'running': False, 'complete': True, 'stage': 'restore'})
        except Exception as e:
            _mlog(f'ERROR: {e}')
            MIGRATE_STATE.update({'running': False, 'error': True})

    @app.route('/api/authentik/migrate/restore', methods=['POST'])
    @login_required
    def authentik_migrate_restore():
        if MIGRATE_STATE.get('running'):
            return jsonify({'error': 'Migration step already in progress'}), 409
        threading.Thread(target=_run_restore, daemon=True).start()
        return jsonify({'success': True})

    # ------------------------------------------------------------------
    # Step 3 — point Caddy + console settings at the new machine
    # ------------------------------------------------------------------
    def _run_repoint(new_ip):
        MIGRATE_STATE.update({'running': True, 'stage': 'repoint', 'complete': False, 'error': False})
        MIGRATE_LOG.clear()
        try:
            if not _IP_RE.match(new_ip or ''):
                _mlog(f'ERROR: invalid IP: {new_ip}')
                MIGRATE_STATE.update({'running': False, 'error': True})
                return
            repoint_script = os.path.join(SCRIPTS_DIR, 'authentik-repoint-caddy.sh')
            _mlog(f'Pointing console + Caddy at {new_ip}:9090...')
            ok, out = _run_local(f'bash "{repoint_script}" {new_ip}', timeout=60)
            _mlog(out)
            MIGRATE_STATE.update({'running': False, 'complete': ok, 'error': not ok, 'stage': 'repoint'})
            if ok:
                _save_state(load_settings, save_settings, chosen_ip=new_ip)
        except Exception as e:
            _mlog(f'ERROR: {e}')
            MIGRATE_STATE.update({'running': False, 'error': True})

    @app.route('/api/authentik/migrate/repoint', methods=['POST'])
    @login_required
    def authentik_migrate_repoint():
        if MIGRATE_STATE.get('running'):
            return jsonify({'error': 'Migration step already in progress'}), 409
        data = request.get_json() or {}
        new_ip = (data.get('ip') or '').strip()
        threading.Thread(target=_run_repoint, args=(new_ip,), daemon=True).start()
        return jsonify({'success': True})

    @app.route('/api/authentik/migrate/log')
    @login_required
    def authentik_migrate_log():
        idx = request.args.get('index', 0, type=int)
        return jsonify({
            'entries': MIGRATE_LOG[idx:], 'total': len(MIGRATE_LOG),
            'running': MIGRATE_STATE['running'], 'stage': MIGRATE_STATE['stage'],
            'complete': MIGRATE_STATE['complete'], 'error': MIGRATE_STATE['error'],
        })

    # ------------------------------------------------------------------
    # Self-update — pulls this module's own repo and re-syncs it into the
    # running console. This is the "download changes" button.
    # ------------------------------------------------------------------
    def _run_self_update():
        SELF_UPDATE_STATE.update({'running': True, 'complete': False, 'error': False, 'restarted': False})
        SELF_UPDATE_LOG.clear()
        try:
            install_sh = os.path.join(MODULE_CHECKOUT_DIR, 'install.sh')
            if not os.path.exists(install_sh):
                _sulog(f'ERROR: module checkout not found at {MODULE_CHECKOUT_DIR}. Run install.sh once by hand first.')
                SELF_UPDATE_STATE.update({'running': False, 'error': True})
                return
            _sulog('git pull on module repo + re-sync into console...')
            ok, out = _run_local(f'bash "{install_sh}" --sync', timeout=180)
            _sulog(out)
            if not ok:
                SELF_UPDATE_STATE.update({'running': False, 'error': True})
                return
            _sulog(f'Restarting {CONSOLE_SERVICE} to load any route/UI changes...')
            ok2, out2 = _run_local(f'systemctl restart {CONSOLE_SERVICE}', timeout=30)
            _sulog(out2 or ('ok' if ok2 else 'restart command failed'))
            SELF_UPDATE_STATE.update({'running': False, 'complete': True, 'restarted': ok2})
        except Exception as e:
            _sulog(f'ERROR: {e}')
            SELF_UPDATE_STATE.update({'running': False, 'error': True})

    @app.route('/api/authentik/migrate/self-update', methods=['POST'])
    @login_required
    def authentik_migrate_self_update():
        if SELF_UPDATE_STATE.get('running'):
            return jsonify({'error': 'Update already in progress'}), 409
        # The console process restarts mid-update — respond immediately and
        # let the UI poll the log until the connection drops, then reload.
        threading.Thread(target=_run_self_update, daemon=True).start()
        return jsonify({'success': True})

    @app.route('/api/authentik/migrate/self-update/log')
    @login_required
    def authentik_migrate_self_update_log():
        idx = request.args.get('index', 0, type=int)
        return jsonify({
            'entries': SELF_UPDATE_LOG[idx:], 'total': len(SELF_UPDATE_LOG),
            'running': SELF_UPDATE_STATE['running'], 'complete': SELF_UPDATE_STATE['complete'],
            'error': SELF_UPDATE_STATE['error'], 'restarted': SELF_UPDATE_STATE['restarted'],
        })

    # ------------------------------------------------------------------
    # Uninstall — removes this module's registration + button from app.py,
    # deletes migrate_authentik.py, restarts the console. Leaves
    # scripts/authentik-migrate/*.sh alone (infra-TAK's own toolkit).
    # ------------------------------------------------------------------
    def _run_uninstall():
        UNINSTALL_STATE.update({'running': True, 'complete': False, 'error': False, 'restarted': False})
        UNINSTALL_LOG.clear()
        try:
            uninstall_sh = os.path.join(MODULE_CHECKOUT_DIR, 'uninstall.sh')
            if not os.path.exists(uninstall_sh):
                _uilog(f'ERROR: module checkout not found at {MODULE_CHECKOUT_DIR}.')
                UNINSTALL_STATE.update({'running': False, 'error': True})
                return
            _uilog('Removing module registration + button from app.py...')
            ok, out = _run_local(f'bash "{uninstall_sh}"', timeout=60)
            _uilog(out)
            UNINSTALL_STATE.update({'running': False, 'complete': ok, 'error': not ok, 'restarted': ok})
        except Exception as e:
            _uilog(f'ERROR: {e}')
            UNINSTALL_STATE.update({'running': False, 'error': True})

    @app.route('/api/authentik/migrate/uninstall', methods=['POST'])
    @login_required
    def authentik_migrate_uninstall():
        if UNINSTALL_STATE.get('running'):
            return jsonify({'error': 'Uninstall already in progress'}), 409
        # Console restarts mid-uninstall (this route's own module gets
        # unregistered) — respond immediately, UI polls the log until the
        # connection drops.
        threading.Thread(target=_run_uninstall, daemon=True).start()
        return jsonify({'success': True})

    @app.route('/api/authentik/migrate/uninstall/log')
    @login_required
    def authentik_migrate_uninstall_log():
        idx = request.args.get('index', 0, type=int)
        return jsonify({
            'entries': UNINSTALL_LOG[idx:], 'total': len(UNINSTALL_LOG),
            'running': UNINSTALL_STATE['running'], 'complete': UNINSTALL_STATE['complete'],
            'error': UNINSTALL_STATE['error'], 'restarted': UNINSTALL_STATE['restarted'],
        })


MIGRATE_TEMPLATE = '''<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Migrate Authentik — infra-TAK</title>
<style>
:root{--bg-deep:#080b14;--bg-surface:#0f1219;--bg-card:#161b26;--border:#1e2736;--text-primary:#f1f5f9;--text-secondary:#cbd5e1;--text-dim:#94a3b8;--accent:#3b82f6;--cyan:#06b6d4;--green:#10b981;--red:#ef4444;--yellow:#eab308}
*{box-sizing:border-box}
body{background:var(--bg-deep);color:var(--text-primary);font-family:'DM Sans',sans-serif;margin:0;padding:32px;max-width:920px}
h1{font-size:20px;margin:0 0 4px}
.sub{color:var(--text-dim);font-size:13px;margin-bottom:24px}
.card{background:var(--bg-card);border:1px solid var(--border);border-radius:12px;padding:22px;margin-bottom:18px}
.card-title{font-size:13px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:.08em;margin-bottom:14px}
.form-label{display:block;font-size:12px;color:var(--text-secondary);margin-bottom:6px}
.form-input{width:100%;background:#0a0e1a;border:1px solid var(--border);border-radius:8px;padding:9px 12px;color:var(--text-primary);font-size:13px;font-family:'DM Sans',sans-serif;margin-bottom:12px}
.row{display:flex;gap:12px}
.row .form-input{flex:1}
.btn{padding:9px 18px;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;border:1px solid var(--border);background:rgba(255,255,255,.05);color:var(--text-secondary)}
.btn-primary{background:var(--accent);color:#fff;border-color:var(--accent)}
.btn-primary:disabled,.btn:disabled{opacity:.5;cursor:not-allowed}
.btn-ghost{background:transparent}
pre#log{background:#05070c;border:1px solid var(--border);border-radius:8px;padding:12px;font-family:'JetBrains Mono',monospace;font-size:11.5px;color:var(--text-secondary);max-height:280px;overflow-y:auto;white-space:pre-wrap}
.hint{font-size:11px;color:var(--text-dim);margin-top:-6px;margin-bottom:12px}
.status{font-size:12px;font-weight:600;margin-left:10px}
.status.ok{color:var(--green)}.status.err{color:var(--red)}
a.back{color:var(--cyan);text-decoration:none;font-size:12px}
.btn-danger{background:rgba(239,68,68,.12);color:var(--red);border-color:rgba(239,68,68,.3)}
</style></head>
<body>
<a class="back" href="/authentik">&larr; Back to Authentik</a>
<h1>Migrate Authentik to a new machine</h1>
<div class="sub">Backs up Authentik from the machine it runs on today (detected automatically — no input needed), restores it on the new machine you specify below, then points Caddy + this console at it. Mirrors scripts/authentik-migrate — nothing here touches the current machine destructively.</div>

<div class="card">
  <div class="card-title">1 &middot; New machine <span style="text-transform:none;font-weight:400;color:var(--text-dim)">(the machine you're moving Authentik TO)</span></div>
  <div class="row">
    <div style="flex:2">
      <label class="form-label">Host / IP</label>
      <input class="form-input" id="new-host" placeholder="192.0.2.10" value="{{ new_machine.host or '' }}">
    </div>
    <div>
      <label class="form-label">SSH user</label>
      <input class="form-input" id="new-user" value="{{ new_machine.ssh_user or 'root' }}">
    </div>
    <div>
      <label class="form-label">SSH port</label>
      <input class="form-input" id="new-port" value="{{ new_machine.ssh_port or 22 }}">
    </div>
  </div>
  <label class="form-label">Auth</label>
  <select class="form-input" id="new-auth">
    <option value="ssh_key" {% if new_machine.auth_method != 'password' %}selected{% endif %}>SSH key</option>
    <option value="password" {% if new_machine.auth_method == 'password' %}selected{% endif %}>Password</option>
  </select>
  <input class="form-input" id="new-key" placeholder="~/.ssh/id_ed25519" value="{{ new_machine.ssh_key_path or '~/.ssh/id_ed25519' }}">
  <input class="form-input" id="new-pass" type="password" placeholder="SSH password (if using password auth)">
  <button class="btn btn-ghost" onclick="saveNewMachine()">Save new machine</button>
  <button class="btn btn-ghost" onclick="testNewMachineSsh()">Test SSH</button>
  <span id="ssh-status" class="status"></span>
</div>

<div class="card">
  <div class="card-title">2 &middot; Back up the current machine <span style="text-transform:none;font-weight:400;color:var(--text-dim)">(wherever Authentik runs today)</span></div>
  <div class="hint">Auto-detected from infra-TAK's existing Authentik deployment config (local or remote) — nothing to fill in here. Live pg_dump, no downtime.</div>
  {% if last_backup %}<div class="hint">Last backup: {{ last_backup.path }} ({{ last_backup.created }})</div>{% endif %}
  <button class="btn btn-primary" id="btn-backup" onclick="runStep('backup')">Run backup</button>
  <a href="/api/authentik/migrate/backup/download"><button class="btn btn-ghost" {% if not last_backup %}disabled{% endif %}>Download tarball</button></a>
</div>

<div class="card">
  <div class="card-title">3 &middot; Restore on the new machine</div>
  <div class="hint">Copies the backup + installs Docker if needed, restores the DB before Authentik ever boots against it, brings the stack up. Uses the new machine from step 1.</div>
  <button class="btn btn-primary" id="btn-restore" onclick="runStep('restore')">Copy + restore on new machine</button>
</div>

<div class="card">
  <div class="card-title">4 &middot; Point console + Caddy at the new machine</div>
  <div class="hint">Runs locally on this console. Enter the IP the restore step reported (or 127.0.0.1 if the new machine IS this console).</div>
  <input class="form-input" id="caddy-ip" placeholder="New Authentik IP" value="{{ chosen_ip or '' }}">
  <button class="btn btn-primary" id="btn-repoint" onclick="runRepoint()">Point console + Caddy now</button>
</div>

<div class="card">
  <div class="card-title">Live log</div>
  <pre id="log">(idle)</pre>
</div>

<div class="card">
  <div class="card-title">Module updates</div>
  <div class="hint">Pulls the latest InfraTAK-Module-MigrateAuthentik changes and re-syncs them into this console (restarts the console service to load them).</div>
  <button class="btn btn-ghost" id="btn-selfupdate" onclick="selfUpdate()">Download changes &amp; apply</button>
  <span id="su-status" class="status"></span>
  <pre id="su-log" style="margin-top:10px;display:none"></pre>
</div>

<div class="card">
  <div class="card-title">Remove module</div>
  <div class="hint">Removes the Migrate button and this wizard from the console (restarts the console service). Does not touch scripts/authentik-migrate — that's infra-TAK's own toolkit — and does not undo any migration you already ran.</div>
  <button class="btn btn-danger" id="btn-uninstall" onclick="uninstallModule()">Uninstall module</button>
  <span id="ui-status" class="status"></span>
  <pre id="ui-log" style="margin-top:10px;display:none"></pre>
</div>

<script>
function collectNewMachine(){
  return {
    host: document.getElementById('new-host').value.trim(),
    ssh_user: document.getElementById('new-user').value.trim() || 'root',
    ssh_port: parseInt(document.getElementById('new-port').value) || 22,
    auth_method: document.getElementById('new-auth').value,
    ssh_key_path: document.getElementById('new-key').value.trim(),
    ssh_password: document.getElementById('new-pass').value,
  };
}
function saveNewMachine(){
  fetch('/api/authentik/migrate/new-machine',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(collectNewMachine()),credentials:'same-origin'})
    .then(r=>r.json()).then(d=>{document.getElementById('ssh-status').textContent=d.success?'saved':'error';});
}
function testNewMachineSsh(){
  var st=document.getElementById('ssh-status'); st.textContent='testing...'; st.className='status';
  saveNewMachine();
  fetch('/api/authentik/migrate/new-machine/test-ssh',{method:'POST',credentials:'same-origin'})
    .then(r=>r.json()).then(d=>{ st.textContent=d.success?'reachable':('failed: '+(d.output||d.error||'')); st.className='status '+(d.success?'ok':'err'); });
}
var pollTimer=null;
function pollLog(){
  fetch('/api/authentik/migrate/log?index=0',{credentials:'same-origin'}).then(r=>r.json()).then(d=>{
    document.getElementById('log').textContent = d.entries.length ? d.entries.join('\\n') : '(idle)';
    document.getElementById('log').scrollTop = document.getElementById('log').scrollHeight;
    if(!d.running){ clearInterval(pollTimer); setButtons(false); }
  });
}
function setButtons(disabled){
  ['btn-backup','btn-restore','btn-repoint'].forEach(id=>document.getElementById(id).disabled=disabled);
}
function runStep(step){
  setButtons(true);
  fetch('/api/authentik/migrate/'+step,{method:'POST',credentials:'same-origin'}).then(r=>r.json()).then(d=>{
    if(d.error){ alert(d.error); setButtons(false); return; }
    pollTimer=setInterval(pollLog,1500); pollLog();
  });
}
function runRepoint(){
  setButtons(true);
  var ip=document.getElementById('caddy-ip').value.trim();
  fetch('/api/authentik/migrate/repoint',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip:ip}),credentials:'same-origin'})
    .then(r=>r.json()).then(d=>{
      if(d.error){ alert(d.error); setButtons(false); return; }
      pollTimer=setInterval(pollLog,1500); pollLog();
    });
}
function selfUpdate(){
  var st=document.getElementById('su-status'); st.textContent='updating...'; st.className='status';
  var log=document.getElementById('su-log'); log.style.display='block';
  document.getElementById('btn-selfupdate').disabled=true;
  fetch('/api/authentik/migrate/self-update',{method:'POST',credentials:'same-origin'}).then(r=>r.json()).then(d=>{
    if(d.error){ st.textContent=d.error; st.className='status err'; document.getElementById('btn-selfupdate').disabled=false; return; }
    var t=setInterval(function(){
      fetch('/api/authentik/migrate/self-update/log?index=0',{credentials:'same-origin'}).then(r=>r.json()).then(function(dd){
        log.textContent = dd.entries.join('\\n');
        if(!dd.running){
          clearInterval(t);
          st.textContent = dd.error ? 'failed' : (dd.restarted ? 'applied — console restarted, reloading...' : 'applied');
          st.className='status '+(dd.error?'err':'ok');
          if(!dd.error && dd.restarted){ setTimeout(function(){ window.location.reload(); }, 4000); }
          else { document.getElementById('btn-selfupdate').disabled=false; }
        }
      }).catch(function(){
        // console process restarting — expected mid-update
        st.textContent='console restarting...';
      });
    }, 1500);
  });
}
function uninstallModule(){
  if(!confirm('Remove the Migrate Authentik module from this console? This restarts the console service. Your migration scripts and any backups already taken are left in place.')) return;
  var st=document.getElementById('ui-status'); st.textContent='uninstalling...'; st.className='status';
  var log=document.getElementById('ui-log'); log.style.display='block';
  document.getElementById('btn-uninstall').disabled=true;
  fetch('/api/authentik/migrate/uninstall',{method:'POST',credentials:'same-origin'}).then(r=>r.json()).then(d=>{
    if(d.error){ st.textContent=d.error; st.className='status err'; document.getElementById('btn-uninstall').disabled=false; return; }
    var t=setInterval(function(){
      fetch('/api/authentik/migrate/uninstall/log?index=0',{credentials:'same-origin'}).then(r=>r.json()).then(function(dd){
        log.textContent = dd.entries.join('\\n');
        if(!dd.running){
          clearInterval(t);
          st.textContent = dd.error ? 'failed' : 'removed — console restarted, redirecting...';
          st.className='status '+(dd.error?'err':'ok');
          if(!dd.error){ setTimeout(function(){ window.location.href='/authentik'; }, 4000); }
          else { document.getElementById('btn-uninstall').disabled=false; }
        }
      }).catch(function(){
        st.textContent='console restarting...';
      });
    }, 1500);
  });
}
</script>
</body></html>'''
