# Starts the loop (and the context watchdog when Python is available) in the background.
param([string]$Config = '', [int]$StartRound = 0, [ValidateSet('A','C','G','B')][string]$StartPhase = 'A')
$kit = $PSScriptRoot
if (-not $Config) { $Config = Join-Path $kit 'loop.config.json' }
$cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
$loop = $cfg.loopDir; if (-not (Test-Path -LiteralPath $loop)) { New-Item -ItemType Directory -Path $loop | Out-Null }
if (Test-Path -LiteralPath "$loop/loop.pid") {
    $old = [int]((Get-Content -LiteralPath "$loop/loop.pid" -Raw).Trim())
    if (Get-Process -Id $old -ErrorAction SilentlyContinue) { Write-Host "Loop already running (pid $old). Run stop-loop.cmd first."; exit 1 }
}
$ps = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if (-not $ps) { $ps = (Get-Command powershell).Source }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$argList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',"$kit/run-loop.ps1",'-Config',$Config,'-StartPhase',$StartPhase)
if ($StartRound -gt 0) { $argList += @('-StartRound',"$StartRound") }
$p = Start-Process -FilePath $ps -ArgumentList $argList -WorkingDirectory $cfg.repoDir -WindowStyle Hidden -RedirectStandardOutput "$loop/loop-$stamp.out.log" -RedirectStandardError "$loop/loop-$stamp.err.log" -PassThru
Set-Content -LiteralPath "$loop/loop.pid" -Value $p.Id
Write-Host "Loop started (pid $($p.Id)). Status: $loop\status.json  Log: $loop\loop.log"
$py = $null; foreach ($c in @('python','py','python3')) { $g = Get-Command $c -ErrorAction SilentlyContinue; if ($g) { $py = $g.Source; break } }
if ($py) {
    $w = Start-Process -FilePath $py -ArgumentList @("$kit/tools/watch-context.py", $Config) -WindowStyle Hidden -RedirectStandardOutput "$loop/watch.out.log" -RedirectStandardError "$loop/watch.err.log" -PassThru
    Set-Content -LiteralPath "$loop/watch.pid" -Value $w.Id; Write-Host "Context watchdog started (pid $($w.Id))."
} else { Write-Host 'Python not found: context watchdog not started (the loop still works; agents checkpoint themselves).' }
