# Agent loop kit - generic B -> A -> C -> root gate loop for any git repository.
# Graph per round: ENV(soft) -> CONTEXT -> A -> ENV(required) -> CONTEXT -> C -> ROOT GATE -> CONTEXT -> B -> METRICS
# Works on Windows PowerShell 5.1 and PowerShell 7. Configure loop.config.json next to this file.
param([string]$Config = '', [int]$StartRound = 0, [ValidateSet('A','C','G','B')][string]$StartPhase = 'A', [int]$RoundLimit = 0)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
try { [Console]::OutputEncoding = $utf8; [Console]::InputEncoding = $utf8 } catch { }
$kit = $PSScriptRoot
if (-not $Config) { $Config = Join-Path $kit 'loop.config.json' }
$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$repo = $cfg.repoDir; $loop = $cfg.loopDir; $project = $cfg.projectName
$branch = if ($cfg.branch) { $cfg.branch } else { 'main' }
$pushRemotes = @(if ($cfg.pushRemotes) { $cfg.pushRemotes } else { 'origin' })
$protected = @(if ($cfg.protectedPaths) { $cfg.protectedPaths } else { @() })
if ($RoundLimit -le 0) { $RoundLimit = if ($cfg.roundLimit) { [int]$cfg.roundLimit } else { 999 } }
$maxWait = if ($env:LOOP_MAX_WAIT_SECONDS) { [int]$env:LOOP_MAX_WAIT_SECONDS } elseif ($cfg.maxLimitWaitSeconds) { [int]$cfg.maxLimitWaitSeconds } else { 21600 }
$claudeCmd = if ($env:LOOP_CLAUDE_CMD) { $env:LOOP_CLAUDE_CMD } else { 'claude' }
$skipServers = [bool]$env:LOOP_SKIP_SERVERS
$isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) -or ($env:OS -eq 'Windows_NT')
foreach ($d in @($loop, "$loop/gates", "$loop/metrics", "$loop/context", "$loop/tasks", "$loop/servers")) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$agentsFile = if ($cfg.agentsFile) { $cfg.agentsFile } else { "$loop/agents.json" }
if (-not (Test-Path -LiteralPath $agentsFile)) { Copy-Item -LiteralPath "$kit/agents.json" -Destination $agentsFile }
if (-not (Test-Path -LiteralPath "$loop/policy.md")) { Copy-Item -LiteralPath "$kit/policy.md" -Destination "$loop/policy.md" }
$roleAgent = @{ planner = 'loop-planner'; implementer = 'loop-implementer'; verifier = 'loop-verifier'; reviewer = 'loop-reviewer' }
if ($cfg.roleAgents) { foreach ($k in @($roleAgent.Keys)) { if ($cfg.roleAgents.$k) { $roleAgent[$k] = "$($cfg.roleAgents.$k)" } } }
if (-not (Test-Path -LiteralPath "$loop/templates")) { Copy-Item -LiteralPath "$kit/templates" -Destination "$loop/templates" -Recurse }
Set-Location -LiteralPath $repo
Set-Content -LiteralPath "$loop/loop.pid" -Value $PID

function Log([string]$m) { $line = "$([DateTime]::UtcNow.ToString('o')) $m"; Add-Content -LiteralPath "$loop/loop.log" -Value $line -Encoding UTF8; Write-Host $line }
function Write-Utf8([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $utf8) }
function Read-Json([string]$path) { if (-not (Test-Path -LiteralPath $path)) { return $null }; try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null } }
function Set-LoopStatus([string]$phase, [int]$round, [string]$detail) { Write-Utf8 "$loop/status.json" (([pscustomobject]@{ phase = $phase; round = $round; detail = $detail; runner = 'agent-loop-kit'; updatedUtc = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json) }
$scriptStamp = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc
function Wait-Until([DateTime]$deadlineUtc) {
    # Waits by the wall clock in short steps: after sleep/standby the wait ends on time instead of being extended.
    while ([DateTime]::UtcNow -lt $deadlineUtc) { Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min(30, [int][Math]::Ceiling(($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)))) }
}
function Stop-Tree([int]$rootPid) {
    $ErrorActionPreference = 'Continue'
    if ($isWin) {
        $all = @(Get-CimInstance Win32_Process); $ids = @($rootPid)
        do { $added = @($all | Where-Object { $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids } | Select-Object -ExpandProperty ProcessId); $ids += $added } while ($added.Count -gt 0)
        foreach ($id in ($ids | Sort-Object -Descending)) { if ($id -ne $rootPid -or (Get-Process -Id $id -ErrorAction SilentlyContinue)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
    } else { & pkill -KILL -P $rootPid 2>$null; Stop-Process -Id $rootPid -Force -ErrorAction SilentlyContinue }
}
function Stop-Leftovers([string]$why) {
    # cleanupProcessPattern (optional): regex for command lines of processes that tests/hooks may leave behind, e.g. "vitest".
    $ErrorActionPreference = 'Continue'
    if (-not $cfg.cleanupProcessPattern) { return }
    $pat = "$($cfg.cleanupProcessPattern)"
    if ($isWin) { $p = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match $pat -and $_.ProcessId -ne $PID }); foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }; $n = $p.Count }
    elseif (Get-Command pgrep -ErrorAction SilentlyContinue) { $n = @(& pgrep -f -- $pat 2>$null).Count; if ($n -gt 0) { & pkill -KILL -f -- $pat 2>$null } } else { $n = 0 }
    if ($n -gt 0) { Log "stopped $n leftover process(es) matching '$pat' ($why)" }
}
function Invoke-GitTimed([string[]]$gitArgs, [string]$logFile, [int]$timeoutSec) {
    # Output goes to files, never a pipeline: leftover hook processes (test workers) can then never hang the loop.
    $ErrorActionPreference = 'Continue'
    $sp = @{ FilePath = (Get-Command git).Source; ArgumentList = $gitArgs; WorkingDirectory = $repo; RedirectStandardOutput = "$logFile.out"; RedirectStandardError = "$logFile.err"; PassThru = $true }
    if ($isWin) { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp; $null = $p.Handle
    if (-not $p.WaitForExit($timeoutSec * 1000)) { Log "git $($gitArgs -join ' ') timed out after $timeoutSec s"; $code = 124 } else { $code = $p.ExitCode }
    Stop-Tree $p.Id; Stop-Leftovers "after git $($gitArgs[0])"
    Write-Utf8 $logFile ((@("$logFile.out", "$logFile.err") | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`n")
    return $code
}
function Get-RemoteHead([string]$remote, [string]$dir) {
    $f = "$dir/ls-remote-$($remote -replace '[^A-Za-z0-9]', '_').log"
    if ((Invoke-GitTimed @('ls-remote', $remote, $branch) $f 120) -ne 0) { return 'unknown' }
    return "$(Get-Content -LiteralPath $f -Raw -Encoding UTF8)".Split("`t")[0].Trim()
}
function Invoke-Node([string]$script) { $ErrorActionPreference = 'Continue'; try { & node "$kit/tools/$script" $loop 2>&1 | ForEach-Object { Log "${script}: $_" } } catch { Log "$script failed: $_" } }
function Invoke-Shell([string]$command, [string]$logFile) {
    $ErrorActionPreference = 'Continue'
    if ($isWin) { & cmd.exe /c "$command > `"$logFile`" 2>&1" } else { & sh -c "$command > '$logFile' 2>&1" }
    return $LASTEXITCODE
}
function Expand-Prompt([string]$name, [int]$round) {
    $src = if (Test-Path -LiteralPath "$loop/prompts/$name") { "$loop/prompts/$name" } else { "$kit/prompts/$name" }
    $t = Get-Content -LiteralPath $src -Raw -Encoding UTF8
    $t = $t.Replace('{{ROUND}}', "$round").Replace('{{NEXT}}', "$($round + 1)").Replace('{{LOOP}}', $loop).Replace('{{REPO}}', $repo).Replace('{{PROJECT}}', $project)
    $policy = Get-Content -LiteralPath "$loop/policy.md" -Raw -Encoding UTF8
    $extra = if (Test-Path -LiteralPath "$loop/policy.local.md") { "`n" + (Get-Content -LiteralPath "$loop/policy.local.md" -Raw -Encoding UTF8) } else { '' }
    return "$t`n`nLOOP POLICY (takes precedence over older task text):`n$policy$extra`nLoop folder: $loop. Repository: $repo. Root's server check: env-status.json. Root gate results: gates/gate-round-N.json."
}

# ---------- environment node ----------
function Get-HttpCode([string]$url) { try { return [int](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20).StatusCode } catch { if ($_.Exception.Response) { try { return [int]$_.Exception.Response.StatusCode } catch { return -1 } }; return 0 } }
function Ensure-Servers([int]$round, [bool]$required) {
    $servers = @($cfg.servers | Where-Object { $_ })
    if ($skipServers -or $servers.Count -eq 0) { Write-Utf8 "$loop/env-status.json" '{"servers":"none or skipped"}'; return $true }
    for ($try = 1; $try -le 3; $try++) {
        $state = [ordered]@{ checkedUtc = [DateTime]::UtcNow.ToString('o'); round = $round; attempt = $try }
        $down = @()
        foreach ($s in $servers) { $code = Get-HttpCode $s.healthUrl; $state[$s.name] = $code; if ($code -lt 200 -or $code -ge 400) { $down += $s } }
        Write-Utf8 "$loop/env-status.json" (([pscustomobject]$state) | ConvertTo-Json)
        if ($down.Count -eq 0) { return $true }
        Set-LoopStatus 'ENV_CHECK' $round "Restarting: $(($down | ForEach-Object { $_.name }) -join ', ')"
        foreach ($s in $down) {
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            $cwd = if ($s.cwd) { $s.cwd } else { $repo }
            $sp = @{ FilePath = $s.startFile; ArgumentList = @($s.startArgs); WorkingDirectory = $cwd; RedirectStandardOutput = "$loop/servers/$($s.name)-$stamp.out.log"; RedirectStandardError = "$loop/servers/$($s.name)-$stamp.err.log"; PassThru = $true }
            if ($isWin) { $sp.WindowStyle = 'Hidden' }
            $p = Start-Process @sp
            Log "started server $($s.name) pid $($p.Id)"
        }
        $deadline = [DateTime]::UtcNow.AddMinutes(4)
        while ([DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 15; $ok = $true; foreach ($s in $servers) { $c = Get-HttpCode $s.healthUrl; if ($c -lt 200 -or $c -ge 400) { $ok = $false } }; if ($ok) { break } }
    }
    $ok = $true; foreach ($s in $servers) { $c = Get-HttpCode $s.healthUrl; if ($c -lt 200 -or $c -ge 400) { $ok = $false } }
    if ($ok) { return $true }
    if ($required) { Set-LoopStatus 'NEEDS_ATTENTION' $round 'Servers not healthy after 3 restarts; C needs the real product. See servers/*.log.'; Log 'env FAILED, stopping'; exit 3 }
    return $false
}

# ---------- agent node with retry ----------
function Get-LimitWaitSeconds([string]$text) {
    $m = [regex]::Match($text, 'resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)', 'IgnoreCase')
    if (-not $m.Success) { return [Math]::Min(1800, $maxWait) }
    $h = [int]$m.Groups[1].Value % 12; if ($m.Groups[3].Value -match 'pm') { $h += 12 }
    $min = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
    $now = [DateTime]::Now; $target = $now.Date.AddHours($h).AddMinutes($min); if ($target -le $now) { $target = $target.AddDays(1) }
    return [Math]::Min([Math]::Max(300, [int]($target - $now).TotalSeconds + 180), $maxWait)
}
function Get-FailureKind($exitCode, $res, [string]$raw) {
    if ($res -and -not $res.is_error -and $exitCode -eq 0) { return 'ok' }
    $text = "$raw"; if ($res) { $text = "$($res.result) $($res.api_error_status) $($res.terminal_reason) $($res.subtype)" }
    if ($text -match 'session limit|usage limit|rate limit|hit your|\b429\b') { return 'limit' }
    if ($text -match 'Failed to authenticate|OAuth|not logged in|Invalid API key|/login|\b401\b') { return 'auth' }
    if (-not $res -or $text -match 'ENOTFOUND|ECONNRESET|ETIMEDOUT|EAI_AGAIN|overloaded|Can.t reach|api_error|\b5\d\d\b|timed out') { return 'transient' }
    return 'fatal'
}
function Invoke-ClaudeJson([string]$label, [string]$prompt, [string[]]$cliArgs, [string]$resultFile, [string]$phase, [int]$round) {
    $ErrorActionPreference = 'Continue'
    $limitWaits = 0; $transient = 0; $transientWaited = 0; $authWaited = 0; $attempt = 0; $ctxRestarts = 0
    $ctxFlag = "$loop/context-restart.flag"
    if (Test-Path -LiteralPath $ctxFlag) { Remove-Item -LiteralPath $ctxFlag -Force -ErrorAction SilentlyContinue }
    while ($true) {
        $attempt++
        $text = $prompt
        if ($attempt -gt 1) { $text += "`nROOT RESUME NOTE: attempt $attempt of this same phase in round $round; the previous attempt stopped early (see $resultFile.attempt$($attempt - 1).json). Preserve partial edits and reports, read your checkpoint and git diff, continue; do not revert or duplicate work." }
        $raw = ($text | & $claudeCmd @cliArgs 2>> "$loop/agent-stderr.log") -join "`n"
        $exitCode = $LASTEXITCODE
        Write-Utf8 $resultFile $raw
        $res = $null; try { $res = $raw | ConvertFrom-Json } catch { }
        $kind = Get-FailureKind $exitCode $res $raw
        if ($kind -eq 'ok') { return $res }
        Copy-Item -LiteralPath $resultFile -Destination "$resultFile.attempt$attempt.json" -Force
        if ((Test-Path -LiteralPath $ctxFlag) -and $ctxRestarts -lt 8) {
            # tools/watch-context.py stopped the agent because its context was nearly full: same phase, fresh session, no wait.
            $ctxRestarts++; $why = (Get-Content -LiteralPath $ctxFlag -Raw -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $ctxFlag -Force -ErrorAction SilentlyContinue
            Log "$label context restart $ctxRestarts (attempt $attempt): continuing phase $phase in a fresh session. $("$why".Trim())"; continue
        }
        if ($kind -eq 'limit' -and $limitWaits -lt 12) {
            $limitWaits++; $why = if ($res) { "$($res.result)" } else { $raw }; $wait = Get-LimitWaitSeconds $why
            Log "$label usage limit (attempt $attempt): waiting $wait s"; Set-LoopStatus 'WAITING_LIMIT' $round "$label paused by usage limit (phase $phase)."
            Wait-Until ([DateTime]::UtcNow.AddSeconds($wait)); continue
        }
        if ($kind -eq 'auth' -and $authWaited -lt $maxWait) {
            # Expired Claude login: tell the user once per wait, then retry every 5 minutes until they log in again.
            $w = [Math]::Min(300, $maxWait - $authWaited); $authWaited += $w
            Log "$label cannot authenticate (attempt $attempt): waiting for a new Claude login; retry in $w s"
            Set-LoopStatus 'NEEDS_LOGIN' $round "Claude login expired. On this computer run: claude, then /login. The loop retries every 5 minutes (phase $phase)."
            Wait-Until ([DateTime]::UtcNow.AddSeconds($w)); continue
        }
        if ($kind -eq 'transient' -and $transientWaited -lt $maxWait) {
            # Network/API outages: back off 2, 5, 10, then every 20 minutes, until maxLimitWaitSeconds in total.
            $transient++; $wait = [Math]::Min(@(120, 300, 600, 1200)[[Math]::Min($transient, 4) - 1], $maxWait - $transientWaited); $transientWaited += $wait
            Log "$label transient failure (attempt $attempt, exit $exitCode): retry in $wait s"; Set-LoopStatus 'WAITING_RETRY' $round "$label retry $transient, waited $([int]($transientWaited / 60)) of $([int]($maxWait / 60)) min (phase $phase)."
            Wait-Until ([DateTime]::UtcNow.AddSeconds($wait)); continue
        }
        throw "$label failed ($kind, exit $exitCode). Inspect $resultFile"
    }
}
function Invoke-Role([string]$role, [string]$modelKey, [string]$promptName, [string]$phase, [int]$round, [string]$resultFile, [bool]$canEdit) {
    $prompt = Expand-Prompt $promptName $round
    $consult = @($cfg.consultAgents.$modelKey | Where-Object { $_ })
    if (-not $canEdit) {
        if ($consult.Count -gt 0) { $prompt += "`nPROJECT SUBAGENTS: you may consult ONLY these read-only project agents (from the repository's .claude/agents) when they help this round: $($consult -join ', '). Never ask any agent to edit application source; you stay read-only for source, and root refuses to publish a round whose source changed during your phase." }
        else { $prompt += "`nPROJECT SUBAGENTS: none are configured for your role; do not start subagents." }
    } elseif ($consult.Count -gt 0) { $prompt += "`nPROJECT SUBAGENTS worth consulting when relevant: $($consult -join ', ') (plus any the project's rules require, e.g. a code reviewer for 3+ files)." }
    Write-Utf8 ($resultFile -replace '-result\.json$', '-prompt.txt') $prompt
    $cli = @('-p', '--agent', $role, '--agents', $agentsFile, '--permission-mode', 'acceptEdits', '--output-format', 'json')
    $model = $cfg.models.$modelKey; if ($model) { $cli += @('--model', $model) }
    if ($canEdit) { $cli += @('--allowedTools', 'Read,Glob,Grep,Bash,Edit,Write,Agent') } else { $cli += @('--allowedTools', 'Read,Glob,Grep,Bash,Write,Agent') }
    $cli += @('--disallowedTools', 'Bash(git commit:*)', 'Bash(git push:*)')
    [void](Invoke-ClaudeJson $role $prompt $cli $resultFile $phase $round)
}

function Get-SourceFingerprint {
    $ErrorActionPreference = 'Continue'
    $s = (@(git -c core.quotepath=false status --porcelain=v1 -uall) -join "`n") + "`n" + (@(git diff --ignore-cr-at-eol HEAD) -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($s)))).Replace('-', '')
}
function Assert-ReadOnlyPhase([string]$before, [string]$phase, [int]$round) {
    $after = Get-SourceFingerprint
    if ($after -ne $before) { Write-Utf8 "$loop/gates/readonly-violation-round-$round-$phase.txt" "Source changed during read-only phase $phase of round $round."; Log "WARNING: source changed during $phase of round $round" }
}

# ---------- root gate node ----------
function Write-Gate([int]$round, [string]$status, [string]$reason, $extra) {
    $o = [ordered]@{ round = $round; status = $status; reason = $reason; checkedUtc = [DateTime]::UtcNow.ToString('o') }
    if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
    Write-Utf8 "$loop/gates/gate-round-$round.json" (([pscustomobject]$o) | ConvertTo-Json -Depth 6); Log "gate round ${round}: $status - $reason"
}
function Get-RealChangedPaths {
    $ErrorActionPreference = 'Continue'
    $paths = @()
    foreach ($l in @(git -c core.quotepath=false status --porcelain=v1 -uall)) {
        if ($l.Length -lt 4) { continue }
        $code = $l.Substring(0, 2); $p = $l.Substring(3).Trim('"'); if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
        if ($code -eq '??') { $paths += $p; continue }
        & git diff --ignore-cr-at-eol --quiet HEAD -- $p; if ($LASTEXITCODE -ne 0) { $paths += $p }
    }
    return $paths
}
function Invoke-RootGate([int]$round) {
    $ErrorActionPreference = 'Continue'
    Set-LoopStatus 'G_ROOT_GATE' $round 'Root gate: verify, independent review, commit and push of C-verified work.'
    if (Test-Path -LiteralPath "$loop/gates/readonly-violation-round-$round-C.txt") { Write-Gate $round 'blocked' 'source changed during C (read-only phase); root must inspect' $null; return }
    $c = Read-Json "$loop/c-round-$round.json"
    if (-not $c) { Write-Gate $round 'skipped' 'no c-round json' $null; return }
    if ($c.taskStatus -ne 'PASS') { Write-Gate $round 'skipped' "C taskStatus $($c.taskStatus)" $null; return }
    $severe = @($c.bugs | Where-Object { $_.severity -in @('critical', 'high') })
    if ($severe.Count -gt 0) { Write-Gate $round 'skipped' "C reported $($severe.Count) critical/high bug(s)" $null; return }
    $head = (git rev-parse HEAD).Trim()
    $paths = @(Get-RealChangedPaths)
    if ($paths.Count -eq 0) { Write-Gate $round 'skipped' 'no real changes' @{ head = $head }; return }
    $prot = @($paths | Where-Object { $_ -in $protected }); if ($prot.Count -gt 0) { Write-Gate $round 'blocked' "protected file changed: $($prot -join ', ')" @{ head = $head; paths = $paths }; return }
    $g = "$loop/gates/round-$round"; if (-not (Test-Path $g)) { New-Item -ItemType Directory -Path $g | Out-Null }
    Write-Utf8 "$g/paths.txt" ($paths -join "`n")
    Stop-Leftovers 'before verify'
    if ($cfg.verifyCommand) { $rc = Invoke-Shell $cfg.verifyCommand "$g/verify.log"; if ($rc -ne 0) { Write-Gate $round 'failed' "verify exit $rc (gates/round-$round/verify.log)" @{ head = $head; paths = $paths }; return } }
    $tracked = @($paths | Where-Object { (git ls-files -- $_) }); $untracked = @($paths | Where-Object { $_ -notin $tracked })
    if ($tracked.Count -gt 0) { & git -c core.quotepath=false diff --ignore-cr-at-eol HEAD -- @tracked | Out-File -LiteralPath "$g/diff.patch" -Encoding utf8 } else { Write-Utf8 "$g/diff.patch" '' }
    Write-Utf8 "$g/untracked.txt" ($untracked -join "`n")
    $reviewPrompt = "Root pre-commit review for $project. Repository: $repo (HEAD $head). Candidate commit = the paths in $g/paths.txt. Tracked changes: $g/diff.patch (CR-at-EOL ignored). New files: $g/untracked.txt (read them in the repository). C verified the round (c-round-$round.json PASS) and the verify command passed ($g/verify.log). First line: COMMIT: OK or COMMIT: BLOCK (reason)."
    if (Test-Path -LiteralPath "$loop/prompts/review.md") { $reviewPrompt += "`nProject review focus:`n" + (Get-Content -LiteralPath "$loop/prompts/review.md" -Raw -Encoding UTF8).Replace('{{ROUND}}', "$round").Replace('{{LOOP}}', $loop).Replace('{{REPO}}', $repo) }
    $cli = @('-p', '--agent', $roleAgent.reviewer, '--agents', $agentsFile, '--permission-mode', 'default', '--output-format', 'json', '--allowedTools', 'Read,Glob,Grep')
    $model = $cfg.models.reviewer; if ($model) { $cli += @('--model', $model) }
    try { $rev = Invoke-ClaudeJson 'root-reviewer' $reviewPrompt $cli "$g/review-result.json" 'G' $round } catch { Write-Gate $round 'failed' "reviewer failed: $_" @{ head = $head; paths = $paths }; return }
    Write-Utf8 "$g/review.md" "$($rev.result)"
    if ("$($rev.result)" -notmatch 'COMMIT:\s*OK') { Write-Gate $round 'blocked' 'reviewer did not return COMMIT: OK (see review.md)' @{ head = $head; paths = $paths }; return }
    Add-Content -LiteralPath "$loop/root-review.md" -Encoding UTF8 -Value "`n## Round $round ($([DateTime]::UtcNow.ToString('yyyy-MM-dd')))`nCOMMIT OK. Findings for B: gates/round-$round/review.md`n"
    $since = Read-Json "$loop/last-publication.json"; $first = if ($since) { [int]$since.round + 1 } else { 1 }
    $title = ((Get-Content -LiteralPath "$loop/current-task.md" -TotalCount 1 -Encoding UTF8) -replace '^#\s*CURRENT TASK\s*[-—]\s*', '').Trim(); if ($title.Length -gt 60) { $title = $title.Substring(0, 60).TrimEnd() }
    $type = if ($cfg.commitType) { $cfg.commitType } else { 'feat' }; $scope = if ($cfg.commitScope) { "($($cfg.commitScope))" } else { '' }
    Write-Utf8 "$g/commit-msg.txt" "${type}${scope}: verified loop rounds $first-$round`n`n$title`n`nRoot gate: C PASS (c-round-$round.json), verify ok, independent review COMMIT OK."
    & git add -A -- @paths
    & git commit -q -F "$g/commit-msg.txt"
    if ($LASTEXITCODE -ne 0) { & git reset -q; Write-Gate $round 'failed' 'git commit failed (hooks?)' @{ head = $head; paths = $paths }; return }
    $commit = (git rev-parse HEAD).Trim(); $remoteState = @{}; $pushFailed = @()
    $timeout = if ($cfg.pushTimeoutSeconds) { [int]$cfg.pushTimeoutSeconds } else { 1800 }
    foreach ($r in $pushRemotes) {
        for ($try = 1; $try -le 2; $try++) {
            $rc = Invoke-GitTimed @('push', $r, $branch) "$g/push-$($r -replace '[^A-Za-z0-9]', '_')-$try.log" $timeout
            Log "push ${r} (try $try): exit $rc"
            $remoteState[$r] = Get-RemoteHead $r $g
            if ($rc -eq 0 -or $remoteState[$r] -eq $commit) { break }
            if ($try -eq 1) { Start-Sleep -Seconds 60 }
        }
        if ($remoteState[$r] -ne $commit) { $pushFailed += $r }
    }
    if ($pushFailed.Count -gt 0) { Write-Gate $round 'committed_not_pushed' "push failed: $($pushFailed -join ', ')" @{ head = $head; commit = $commit; paths = $paths; remotes = $remoteState }; return }
    $pub = [pscustomobject]@{ round = $round; commit = $commit; base = $head; rounds = "$first-$round"; publishedUtc = [DateTime]::UtcNow.ToString('o'); remotes = $remoteState }
    Write-Utf8 "$loop/last-publication.json" ($pub | ConvertTo-Json -Depth 5); Add-Content -LiteralPath "$loop/publications.jsonl" -Value ($pub | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
    Write-Gate $round 'published' "commit $commit pushed" @{ head = $head; commit = $commit; paths = $paths; remotes = $remoteState }
}

# ---------- main graph ----------
if (-not (Test-Path -LiteralPath "$loop/current-task.md")) {
    if (-not (Test-Path -LiteralPath "$loop/requirements.md")) { Set-LoopStatus 'NEEDS_ATTENTION' 0 "Write $loop/requirements.md (the full requirement list) first."; Log 'requirements.md missing'; exit 2 }
    Set-LoopStatus 'B_BOOTSTRAP' 0 'B turns requirements.md into backlog.json and round 1.'
    Invoke-Role $roleAgent.planner 'planner' 'B0-initial.md' 'B' 0 "$loop/b-round-0-result.json" $false
    Invoke-Node 'loop-metrics.mjs'
    if (-not (Test-Path -LiteralPath "$loop/current-task.md")) { Set-LoopStatus 'NEEDS_ATTENTION' 0 'B did not create current-task.md (see b-round-0.md).'; exit 2 }
    $d = Read-Json "$loop/b-next.json"; if ($d -and $d.decision -eq 'BLOCKED') { Set-LoopStatus 'NEEDS_ATTENTION' 0 $d.reason; exit 0 }
    if ($StartRound -le 0) { $StartRound = 1 }
}
if ($StartRound -le 0) { $last = Read-Json "$loop/status.json"; $StartRound = if ($last -and [int]$last.round -gt 0) { [int]$last.round } else { 1 } }
$finalRound = $StartRound + $RoundLimit - 1
Log "loop start: project $project, round $StartRound phase $StartPhase, until round $finalRound"
for ($round = $StartRound; $round -le $finalRound; $round++) {
    $first = ($round -eq $StartRound)
    if (-not $first -and (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc -ne $scriptStamp) {
        # run-loop.ps1 was updated on disk: hand over to a fresh runner at this round boundary (no manual restart needed).
        $ps = (Get-Process -Id $PID).Path
        $sp = @{ FilePath = $ps; ArgumentList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Config', $Config, '-StartRound', "$round", '-StartPhase', 'A', '-RoundLimit', "$($finalRound - $round + 1)"); WorkingDirectory = $repo; RedirectStandardOutput = "$loop/loop-r$round.out.log"; RedirectStandardError = "$loop/loop-r$round.err.log"; PassThru = $true }
        if ($isWin) { $sp.WindowStyle = 'Hidden' }
        $p = Start-Process @sp; Set-Content -LiteralPath "$loop/loop.pid" -Value $p.Id
        Log "run-loop.ps1 changed on disk: handed over to a fresh runner (pid $($p.Id)) at round $round"; exit 0
    }
    if (-not $first -or $StartPhase -eq 'A') {
        [void](Ensure-Servers $round $false); Invoke-Node 'build-context.mjs'
        Set-LoopStatus 'A_IMPLEMENTING' $round 'A implements the current task.'
        Invoke-Role $roleAgent.implementer 'implementer' 'A.md' 'A' $round "$loop/a-round-$round-result.json" $true; Invoke-Node 'loop-metrics.mjs'
    }
    if (-not $first -or $StartPhase -in @('A', 'C')) {
        [void](Ensure-Servers $round $true); Invoke-Node 'build-context.mjs'
        Set-LoopStatus 'C_VERIFYING' $round 'C verifies independently.'
        $fp = Get-SourceFingerprint
        Invoke-Role $roleAgent.verifier 'verifier' 'C.md' 'C' $round "$loop/c-round-$round-result.json" $false; Invoke-Node 'loop-metrics.mjs'
        Assert-ReadOnlyPhase $fp 'C' $round
    }
    if (-not $first -or $StartPhase -in @('A', 'C', 'G')) { try { Invoke-RootGate $round } catch { Write-Gate $round 'failed' "gate exception: $_" $null } }
    Invoke-Node 'build-context.mjs'
    Set-LoopStatus 'B_PLANNING_NEXT' $round 'B closes the round and plans the next.'
    $fp = Get-SourceFingerprint
    Invoke-Role $roleAgent.planner 'planner' 'B.md' 'B' $round "$loop/b-round-$round-result.json" $false; Invoke-Node 'loop-metrics.mjs'
    Assert-ReadOnlyPhase $fp 'B' $round
    $d = Read-Json "$loop/b-next.json"
    if ($d.decision -eq 'COMPLETE') { Set-LoopStatus 'AWAITING_ROOT_VERIFICATION' $round 'B reports COMPLETE; verify the result yourself.'; exit 0 }
    if ($d.decision -eq 'BLOCKED') { Set-LoopStatus 'NEEDS_ATTENTION' $round $d.reason; exit 0 }
}
Set-LoopStatus 'ROUND_LIMIT_REACHED' $finalRound 'Round limit reached; rerun to continue.'
