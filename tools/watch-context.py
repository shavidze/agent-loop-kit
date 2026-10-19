"""Context watchdog for agent-loop-kit: restarts the same phase in a fresh session when an agent's context
grows past contextRestartTokens or a compaction is detected. Usage: python watch-context.py <loop.config.json>"""
import json, time, subprocess, datetime, shutil, sys, re
from pathlib import Path
CFG = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
KIT = Path(__file__).resolve().parent.parent
LOOP = Path(CFG['loopDir'])
SESSIONS = Path.home() / '.claude' / 'projects' / re.sub(r'[^A-Za-z0-9]', '-', str(Path(CFG['repoDir'])))
LIMIT = int(CFG.get('contextRestartTokens') or 650000)
PS = shutil.which('pwsh') or shutil.which('powershell') or 'powershell'
ACTIVE = {'A_IMPLEMENTING': 'A', 'C_VERIFYING': 'C', 'B_PLANNING_NEXT': 'B', 'B_BOOTSTRAP': 'B'}
def ps(code):
    return subprocess.run([PS, '-NoLogo', '-NoProfile', '-Command', code], capture_output=True, text=True, timeout=90, check=True).stdout
def session_info(phase, started):
    start = datetime.datetime.fromisoformat(started.replace('Z', '+00:00')).timestamp()
    for p in sorted([p for p in SESSIONS.glob('*.jsonl') if p.stat().st_ctime >= start - 2], key=lambda x: abs(x.stat().st_ctime - start)):
        found = False; tokens = 0; compacted = False; last = ''
        for line in p.open(encoding='utf-8', errors='replace'):
            try: row = json.loads(line)
            except json.JSONDecodeError: continue
            if row.get('type') == 'user' and not found:
                c = row.get('message', {}).get('content', '')
                text = c if isinstance(c, str) else '\n'.join(b.get('text', '') for b in c if isinstance(b, dict) and b.get('type') == 'text')
                found = text.startswith(f'You are {phase}.')
            if row.get('type') == 'system' and 'compact' in str(row.get('subtype', '')): compacted = True
            if row.get('type') == 'assistant':
                u = row.get('message', {}).get('usage', {})
                if u: tokens = sum(u.get(k, 0) or 0 for k in ('input_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'output_tokens'))
                for b in row.get('message', {}).get('content', []):
                    if isinstance(b, dict) and b.get('type') == 'text': last = b.get('text', '')[-1500:]
        if found: return p, tokens, compacted, last
    return None, 0, False, ''
while True:
    try:
        st = json.loads((LOOP / 'status.json').read_text(encoding='utf-8-sig'))
        phase = ACTIVE.get(st.get('phase'))
        if not phase: time.sleep(20); continue
        sess, tokens, compacted, last = session_info(phase, st['updatedUtc'])
        (LOOP / 'context-watch-status.json').write_text(json.dumps({'updatedUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'phase': phase, 'round': st['round'], 'session': sess.stem if sess else None, 'contextTokens': tokens, 'limit': LIMIT, 'compacted': compacted}, indent=2), encoding='utf-8')
        if sess and (compacted or tokens >= LIMIT) and st.get('round', 0) > 0:
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            (LOOP / f'context-restart-{stamp}.md').write_text(f'# Fresh-session checkpoint\n\nRound {st["round"]}, phase {phase}, context {tokens}, compacted {compacted}.\nPreserve all partial edits; read the checkpoint, reports and git diff; continue the same phase.\n\nLast agent text:\n\n{last}\n', encoding='utf-8')
            pid = int((LOOP / 'loop.pid').read_text(encoding='utf-8-sig').strip())
            ps(f"$all=Get-CimInstance Win32_Process; $ids=@({pid}); do {{ $add=@($all | Where-Object {{ $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids }} | Select-Object -ExpandProperty ProcessId); $ids+=$add }} while ($add.Count -gt 0); foreach ($i in ($ids | Sort-Object -Descending)) {{ Stop-Process -Id $i -Force -ErrorAction SilentlyContinue }}")
            new_pid = ps(f"$p=Start-Process '{PS}' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File','{KIT / 'run-loop.ps1'}','-Config','{sys.argv[1]}','-StartRound','{st['round']}','-StartPhase','{phase}') -WorkingDirectory '{CFG['repoDir']}' -WindowStyle Hidden -RedirectStandardOutput '{LOOP / ('loop-' + stamp + '.out.log')}' -RedirectStandardError '{LOOP / ('loop-' + stamp + '.err.log')}' -PassThru; $p.Id").strip()
            (LOOP / 'loop.pid').write_text(new_pid, encoding='utf-8')
            with (LOOP / 'context-restarts.jsonl').open('a', encoding='utf-8') as f: f.write(json.dumps({'time': stamp, 'round': st['round'], 'phase': phase, 'tokens': tokens, 'newPid': new_pid}) + '\n')
            time.sleep(60)
        else: time.sleep(20)
    except Exception as exc:
        with (LOOP / 'context-watch-errors.log').open('a', encoding='utf-8') as f: f.write(f'{datetime.datetime.now(datetime.timezone.utc).isoformat()} {type(exc).__name__}: {exc}\n')
        time.sleep(30)
