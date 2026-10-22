"""Context watchdog for agent-loop-kit: when an agent's context grows past contextRestartTokens or a compaction is
detected, the same phase continues in a fresh session. Usage: python watch-context.py <loop.config.json>

contextRestartMode (config):
  "agent"  (default on Linux/macOS) stop only the agent process; run-loop.ps1 sees context-restart.flag and starts
           the same phase again at once, in the same runner (works inside CI jobs too).
  "runner" (default on Windows) stop the whole runner tree and start a new runner at the same round and phase."""
import json, os, time, signal, subprocess, datetime, shutil, sys, re
from pathlib import Path
CFG = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
KIT = Path(__file__).resolve().parent.parent
LOOP = Path(CFG['loopDir'])
SESSIONS = Path.home() / '.claude' / 'projects' / re.sub(r'[^A-Za-z0-9]', '-', str(Path(CFG['repoDir'])))
LIMIT = int(CFG.get('contextRestartTokens') or 650000)
IS_WIN = os.name == 'nt'
MODE = CFG.get('contextRestartMode') or ('runner' if IS_WIN else 'agent')
AGENTS_FILE = str(CFG.get('agentsFile') or (LOOP / 'agents.json'))
PS = shutil.which('pwsh') or shutil.which('powershell') or 'powershell'
ACTIVE = {'A_IMPLEMENTING': 'A', 'C_VERIFYING': 'C', 'B_PLANNING_NEXT': 'B', 'B_BOOTSTRAP': 'B'}
HANDLED = set()

def now_stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')

def ps(code):
    return subprocess.run([PS, '-NoLogo', '-NoProfile', '-Command', code], capture_output=True, text=True, timeout=90, check=True).stdout

def read_session(p, phase):
    found = False; tokens = 0; compacted = False; last = ''
    for line in p.open(encoding='utf-8', errors='replace'):
        try: row = json.loads(line)
        except json.JSONDecodeError: continue
        if row.get('type') == 'user' and not found:
            c = row.get('message', {}).get('content', '')
            text = c if isinstance(c, str) else '\n'.join(b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
            found = text.startswith(f'You are {phase}.')
            if not found: return None
        if row.get('type') == 'system' and 'compact' in str(row.get('subtype', '')): compacted = True
        if row.get('type') == 'assistant':
            u = row.get('message', {}).get('usage', {})
            if u: tokens = sum(u.get(k, 0) or 0 for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens'))
            for b in row.get('message', {}).get('content', []):
                if isinstance(b, dict) and b.get('type') == 'text': last = b.get('text', '')[-1500:]
    return (tokens, compacted, last) if found else None

def session_info(phase, started):
    # The active session is the newest session file of this phase written since the phase started.
    start = datetime.datetime.fromisoformat(started.replace('Z', '+00:00')).timestamp()
    files = sorted((p for p in SESSIONS.glob('*.jsonl') if p.stem not in HANDLED and p.stat().st_mtime >= start - 2), key=lambda x: x.stat().st_mtime, reverse=True)
    for p in files:
        info = read_session(p, phase)
        if info: return (p,) + info
    return None, 0, False, ''

def posix_procs():
    out = subprocess.run(['ps', '-A', '-o', 'pid=,ppid=,args='], capture_output=True, text=True, timeout=30, check=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit(): rows[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else '')
    return rows

def descendants(rows, root):
    ids = [root]; i = 0
    while i < len(ids):
        ids += [pid for pid, (ppid, _) in rows.items() if ppid == ids[i] and pid not in ids]; i += 1
    return ids[1:]

def is_agent(args):
    return '--agents' in args and AGENTS_FILE in args

def stop_agent(runner_pid):
    """Stops the runner's top-level agent processes (and their children). Returns how many agents were stopped."""
    if IS_WIN:
        out = ps(f"$all=Get-CimInstance Win32_Process; $ids=@({runner_pid}); do {{ $add=@($all | Where-Object {{ $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids }} | Select-Object -ExpandProperty ProcessId); $ids+=$add }} while ($add.Count -gt 0); "
                 f"$agents=@($all | Where-Object {{ $_.ProcessId -in $ids -and $_.CommandLine -like '*--agents*' -and $_.CommandLine -like '*{AGENTS_FILE}*' }}); "
                 "foreach ($a in $agents) { $t=@($a.ProcessId); do { $add=@($all | Where-Object { $_.ParentProcessId -in $t -and $_.ProcessId -notin $t } | Select-Object -ExpandProperty ProcessId); $t+=$add } while ($add.Count -gt 0); foreach ($i in ($t | Sort-Object -Descending)) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue } }; $agents.Count")
        return int((out.strip() or '0').splitlines()[-1])
    rows = posix_procs()
    tree = descendants(rows, runner_pid)
    tops = [p for p in tree if is_agent(rows[p][1]) and not is_agent(rows.get(rows[p][0], (0, ''))[1])]
    victims = []
    for t in tops: victims += [t] + descendants(rows, t)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in reversed(victims):
            try: os.kill(pid, sig)
            except (ProcessLookupError, PermissionError): pass
        if sig == signal.SIGTERM and victims: time.sleep(5)
    return len(tops)

def restart_runner(st, phase, stamp):
    pid = int((LOOP / 'loop.pid').read_text(encoding='utf-8-sig').strip())
    ps(f"$all=Get-CimInstance Win32_Process; $ids=@({pid}); do {{ $add=@($all | Where-Object {{ $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids }} | Select-Object -ExpandProperty ProcessId); $ids+=$add }} while ($add.Count -gt 0); foreach ($i in ($ids | Sort-Object -Descending)) {{ Stop-Process -Id $i -Force -ErrorAction SilentlyContinue }}")
    new_pid = ps(f"$p=Start-Process '{PS}' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File','{KIT / 'run-loop.ps1'}','-Config','{sys.argv[1]}','-StartRound','{st['round']}','-StartPhase','{phase}') -WorkingDirectory '{CFG['repoDir']}' -WindowStyle Hidden -RedirectStandardOutput '{LOOP / ('loop-' + stamp + '.out.log')}' -RedirectStandardError '{LOOP / ('loop-' + stamp + '.err.log')}' -PassThru; $p.Id").strip()
    (LOOP / 'loop.pid').write_text(new_pid, encoding='utf-8')
    return new_pid

while True:
    try:
        st = json.loads((LOOP / 'status.json').read_text(encoding='utf-8-sig'))
        phase = ACTIVE.get(st.get('phase'))
        if not phase: time.sleep(20); continue
        sess, tokens, compacted, last = session_info(phase, st['updatedUtc'])
        (LOOP / 'context-watch-status.json').write_text(json.dumps({'updatedUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'phase': phase, 'round': st['round'], 'session': sess.stem if sess else None, 'contextTokens': tokens, 'limit': LIMIT, 'compacted': compacted, 'mode': MODE}, indent=2), encoding='utf-8')
        if sess and (compacted or tokens >= LIMIT) and st.get('round', 0) > 0:
            stamp = now_stamp()
            (LOOP / f'context-restart-{stamp}.md').write_text(f'# Fresh-session checkpoint\n\nRound {st["round"]}, phase {phase}, context {tokens}, compacted {compacted}.\nPreserve all partial edits; read the checkpoint, reports and git diff; continue the same phase.\n\nLast agent text:\n\n{last}\n', encoding='utf-8')
            entry = {'time': stamp, 'round': st['round'], 'phase': phase, 'tokens': tokens, 'compacted': compacted, 'session': sess.stem, 'mode': MODE}
            if MODE == 'agent':
                runner = int((LOOP / 'loop.pid').read_text(encoding='utf-8-sig').strip())
                flag = LOOP / 'context-restart.flag'
                flag.write_text(f'context {tokens} tokens, compacted {compacted}, checkpoint context-restart-{stamp}.md', encoding='utf-8')
                stopped = stop_agent(runner)
                if not stopped: flag.unlink(missing_ok=True); time.sleep(20); continue
                entry['stoppedAgents'] = stopped
            else:
                entry['newPid'] = restart_runner(st, phase, stamp)
            HANDLED.add(sess.stem)
            with (LOOP / 'context-restarts.jsonl').open('a', encoding='utf-8') as f: f.write(json.dumps(entry) + '\n')
            time.sleep(60)
        else: time.sleep(20)
    except Exception as exc:
        with (LOOP / 'context-watch-errors.log').open('a', encoding='utf-8') as f: f.write(f'{datetime.datetime.now(datetime.timezone.utc).isoformat()} {type(exc).__name__}: {exc}\n')
        time.sleep(30)
