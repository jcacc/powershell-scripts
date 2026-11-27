# Headless checks for AdminDeck.Catalog.psm1. No Pester needed:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\AdminDeck\Tests\Catalog.Tests.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = (Resolve-Path (Join-Path $here '..\..')).ProviderPath
Import-Module (Join-Path $here '..\AdminDeck.Catalog.psm1') -Force

$failures = New-Object System.Collections.Generic.List[string]
function Assert($cond, $msg) { if (-not $cond) { $failures.Add($msg) } }

# Windows PowerShell 5.1 reads BOM-less files as ANSI, so AdminDeck's own PowerShell must stay ASCII.
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $here '..') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })) {
    $bad = @([IO.File]::ReadAllBytes($f.FullName) | Where-Object { $_ -gt 127 }).Count
    Assert ($bad -eq 0) "$($f.Name) has $bad non-ASCII bytes"
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$catalog = @(Get-AdScriptCatalog -RepoRoot $repo)
"Catalog: $($catalog.Count) scripts in $([int]$sw.Elapsed.TotalMilliseconds) ms"
Assert ($catalog.Count -ge 150) "expected 150+ scripts, got $($catalog.Count)"
Assert (@($catalog | Where-Object { $_.Id -like 'AdminDeck*' }).Count -eq 0) 'AdminDeck itself must not be in the catalog'
Assert (@($catalog | Group-Object Name | Where-Object Count -gt 1).Count -eq 0) 'duplicate display names'

$sw.Restart()
$kinds = @{}; $withParams = 0; $parseErrors = 0; $totalParams = 0
foreach ($s in $catalog) {
    $info = Get-AdScriptParameters -Path $s.Path
    if ($info.ParseErrors.Count) { $parseErrors++; "  parse errors: $($s.Id): $($info.ParseErrors[0])" }
    if ($info.Parameters.Count) { $withParams++ }
    $values = @{}
    foreach ($p in $info.Parameters) {
        $totalParams++
        $kinds[$p.Kind] = 1 + [int]$kinds[$p.Kind]
        switch ($p.Kind) {
            'Switch' { $values[$p.Name] = $true }
            'Bool'   { $values[$p.Name] = 'True' }
            'Choice' { $values[$p.Name] = $p.Choices[0] }
            'Date'   { $values[$p.Name] = '2026-11-01' }
            'Number' { $values[$p.Name] = '30' }
            'List'   { $values[$p.Name] = "a@contoso.com, b'o@contoso.com" }
            'Secret' { $values[$p.Name] = 'hunter2' }
            'Raw'    { $values[$p.Name] = '$null' }
            default  { $values[$p.Name] = "it's a test" }
        }
    }
    $inv = ConvertTo-AdInvocation -ScriptPath $s.Path -Parameters $info.Parameters -Values $values
    Assert ($inv.Errors.Count -eq 0) "$($s.Id): unexpected errors $($inv.Errors -join '; ')"
    Assert ($inv.Display -notmatch 'hunter2') "$($s.Id): secret leaked into display"
    Assert ($inv.Command -notmatch 'hunter2') "$($s.Id): secret leaked into command"
    # The generated command must itself parse cleanly.
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($inv.Command, [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) "$($s.Id): generated command does not parse: $($inv.Command)"
    $launch = New-AdLaunchScript -Invocation $inv -Title $s.Name -WorkingDirectory (Join-Path ([IO.Path]::GetTempPath()) "it's here") -Transcript
    [void][System.Management.Automation.Language.Parser]::ParseInput($launch, [ref]$t, [ref]$e)
    Assert ($e.Count -eq 0) "$($s.Id): launch script does not parse"
    Assert ($launch -notmatch 'hunter2') "$($s.Id): secret leaked into launch script"
}
"Parsed params of all scripts in $([int]$sw.Elapsed.TotalMilliseconds) ms: $withParams with params, $totalParams params, $parseErrors with parse errors"
"Kinds: " + (($kinds.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')
"Areas: " + (($catalog | Group-Object Area | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', ')
"Modifies tenant: $(@($catalog | Where-Object Modifies).Count); docs links: $(@($catalog | Where-Object DocsUrl).Count)"

# Specific script: failed sign-ins has ValidateSet + nullable datetime.
$fs = $catalog | Where-Object { $_.Id -like 'Audit Failed Signin*' }
$fp = (Get-AdScriptParameters -Path $fs.Path).Parameters
Assert (($fp | Where-Object Name -eq 'SignInEventType').Kind -eq 'Choice') 'SignInEventType should be Choice'
Assert (($fp | Where-Object Name -eq 'StartDate').Kind -eq 'Date') 'StartDate should be Date'
Assert (($fp | Where-Object Name -eq 'StartDate').Hint -match 'YYYY') 'StartDate hint from inline comment'
Assert (($fp | Where-Object Name -eq 'RiskySignInsOnly').Kind -eq 'Switch') 'RiskySignInsOnly should be Switch'
Assert ($fs.Services -contains 'Graph') 'failed sign-ins uses Graph'
Assert ($fs.DocsUrl -match '^https://o365reports.com/') "docs url: $($fs.DocsUrl)"

# Validation.
$num = [pscustomobject]@{ Name = 'Days'; Kind = 'Number'; Choices = @(); AlwaysRequired = $true; TypeName = 'int' }
$bad = ConvertTo-AdInvocation -ScriptPath 'C:\x.ps1' -Parameters @($num) -Values @{ Days = 'abc' }
Assert ($bad.Errors.Count -eq 1 -and $bad.Errors[0] -match 'number') "expected a number error, got: $($bad.Errors -join '; ')"
$miss = ConvertTo-AdInvocation -ScriptPath 'C:\x.ps1' -Parameters @($num) -Values @{ Days = '' }
Assert ($miss.Errors -contains 'Days is required.') "expected required error, got: $($miss.Errors -join '; ')"
$ok = ConvertTo-AdInvocation -ScriptPath 'C:\x.ps1' -Parameters @($num) -Values @{ Days = ' 45 ' } -ExtraArguments '-Verbose'
Assert ($ok.Command -eq "& 'C:\x.ps1' -Days 45 -Verbose") "number command: $($ok.Command)"

# End to end: launch a dummy script the way the GUI does (encoded command, secret via env,
# working folder with an apostrophe) and check what it received.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("AdminDeck test's " + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $tmp | Out-Null
$dummy = Join-Path $tmp 'Dummy Script.ps1'
Set-Content -LiteralPath $dummy -Encoding UTF8 -Value @'
param([string]$Name, [string]$Password, [switch]$Flag, [nullable[datetime]]$StartDate, [string[]]$Users, [int]$Days)
[pscustomobject]@{
    Name = $Name; Password = $Password; Flag = [bool]$Flag; StartDate = $StartDate.ToString('yyyy-MM-dd HH:mm')
    Users = ($Users -join '|'); Days = $Days; Cwd = (Get-Location).Path; EnvLeft = [string]$env:ADECK_SECRET_1
} | Export-Csv -NoTypeInformation -Encoding UTF8 -Path '.\result.csv'
'@
$dp = (Get-AdScriptParameters -Path $dummy).Parameters
$inv = ConvertTo-AdInvocation -ScriptPath $dummy -Parameters $dp -Values @{
    Name = "O'Brien `"quoted`" `$notavar $([char]0x2019)curly$([char]0x2019)"; Password = "p@ss'w`$rd"; Flag = $true; StartDate = '2026-11-01 13:45'; Users = "a@x.com`nb@x.com"; Days = '7'
}
Assert ($inv.Errors.Count -eq 0) "dummy errors: $($inv.Errors -join '; ')"
$launch = New-AdLaunchScript -Invocation $inv -Title 'Dummy' -WorkingDirectory $tmp -Transcript
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
foreach ($k in $inv.Secrets.Keys) { [Environment]::SetEnvironmentVariable($k, $inv.Secrets[$k], 'Process') }
try {
    $sp = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc); WorkingDirectory = $tmp; PassThru = $true; Wait = $true }
    if ($PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows) { $sp.WindowStyle = 'Hidden' }
    $proc = Start-Process @sp
} finally { foreach ($k in $inv.Secrets.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') } }
$out = Join-Path $tmp 'result.csv'
Assert (Test-Path -LiteralPath $out) 'dummy script did not write result.csv into the working folder'
if (Test-Path -LiteralPath $out) {
    $r = Import-Csv -LiteralPath $out
    Assert ($r.Name -eq "O'Brien `"quoted`" `$notavar $([char]0x2019)curly$([char]0x2019)") "name round-trip: $($r.Name)"
    Assert ($r.Password -eq "p@ss'w`$rd") 'secret did not arrive intact'
    Assert ($r.Flag -eq 'True') 'switch not passed'
    Assert ($r.StartDate -eq '2026-11-01 13:45') "date: $($r.StartDate)"
    Assert ($r.Users -eq 'a@x.com|b@x.com') "list: $($r.Users)"
    Assert ($r.Days -eq '7') "number: $($r.Days)"
    Assert ($r.Cwd -eq $tmp.TrimEnd('\')) "cwd: $($r.Cwd)"
    Assert ($r.EnvLeft -eq '') 'secret env var should be removed before the script runs'
}
Assert (@(Get-ChildItem -LiteralPath $tmp -Filter 'transcript_*.txt').Count -eq 1) 'transcript not written'
$tr = Get-ChildItem -LiteralPath $tmp -Filter 'transcript_*.txt' | Select-Object -First 1
if ($tr) { Assert ((Get-Content -LiteralPath $tr.FullName -Raw) -notmatch [regex]::Escape("p@ss'w")) 'secret appears in transcript' }
Remove-Item -LiteralPath $tmp -Recurse -Force
"End-to-end launch: done"

if ($failures.Count) {
    "FAILED ($($failures.Count)):"; $failures | Select-Object -First 30 | ForEach-Object { "  $_" }
    exit 1
}
'ALL PASSED'
