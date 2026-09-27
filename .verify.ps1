$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot   # script's own dir, so this stays correct wherever the project is moved
$sub = Get-ChildItem $dir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'UltraLowPower.ps1') } | Select-Object -First 1
$p = Join-Path $sub.FullName 'UltraLowPower.ps1'

# 1. UTF-8 BOM
$c = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($true)))

# 2. PowerShell parse
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
if ($errs.Count -gt 0) { $errs | Select-Object -First 5 | ForEach-Object { Write-Output ('PARSE ERR line ' + $_.Extent.StartLineNumber + ': ' + $_.Message) }; exit 1 }
Write-Output 'PARSE OK'

# 3. C# blocks compile
$lines = Get-Content $p -Encoding UTF8
$blocks = @()
$inBlock = $false
$name = ''
$cur = $null
foreach ($l in $lines) {
    if (-not $inBlock -and $l -match '^(\$[A-Za-z]+Cs)\s*=\s*@''$') {
        $inBlock = $true; $name = $Matches[1]
        $cur = New-Object System.Collections.Generic.List[string]
        continue
    }
    if ($inBlock -and $l -eq '''@') { $blocks += ,@($name, ($cur -join "`n")); $inBlock = $false; continue }
    if ($inBlock) { $cur.Add($l) }
}
foreach ($b in $blocks) {
    try { Add-Type -TypeDefinition $b[1] -ErrorAction Stop; Write-Output ($b[0] + ' COMPILE OK') }
    catch { Write-Output ($b[0] + ' FAILED: ' + $_.Exception.Message); exit 1 }
}
Write-Output 'ALL CHECKS OK'
