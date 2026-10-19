param([string]$Config = '')
$kit = $PSScriptRoot; if (-not $Config) { $Config = Join-Path $kit 'loop.config.json' }
$loop = (Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json).loopDir
foreach ($f in @('watch.pid','loop.pid')) {
    if (-not (Test-Path -LiteralPath "$loop/$f")) { continue }
    $root = [int]((Get-Content -LiteralPath "$loop/$f" -Raw).Trim())
    $all = Get-CimInstance Win32_Process; $ids = @($root)
    do { $add = @($all | Where-Object { $_.ParentProcessId -in $ids -and $_.ProcessId -notin $ids } | Select-Object -ExpandProperty ProcessId); $ids += $add } while ($add.Count -gt 0)
    foreach ($i in ($ids | Sort-Object -Descending)) { Stop-Process -Id $i -Force -ErrorAction SilentlyContinue }
    Write-Host "stopped $f ($root)"
}
