# AdminDeck.Catalog.psm1
# Discovers the scripts in this repository, reads their metadata and parameters,
# and turns form values into a PowerShell command line. No UI code lives here so it
# can be tested headless (see Tests\Catalog.Tests.ps1).
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+. Keep this file ASCII.

Set-StrictMode -Version 2.0

# Connect-* cmdlet -> service tag and the module it needs.
$script:ConnectMap = [ordered]@{
    'Connect-MgGraph'        = @{ Service = 'Graph';      Module = 'Microsoft.Graph' }
    'Connect-ExchangeOnline' = @{ Service = 'Exchange';   Module = 'ExchangeOnlineManagement' }
    'Connect-IPPSSession'    = @{ Service = 'Purview';    Module = 'ExchangeOnlineManagement' }
    'Connect-PnPOnline'      = @{ Service = 'PnP';        Module = 'PnP.PowerShell' }
    'Connect-SPOService'     = @{ Service = 'SPO';        Module = 'Microsoft.Online.SharePoint.PowerShell' }
    'Connect-MicrosoftTeams' = @{ Service = 'Teams';      Module = 'MicrosoftTeams' }
    'Connect-MsolService'    = @{ Service = 'MSOnline';   Module = 'MSOnline' }
    'Connect-AzureAD'        = @{ Service = 'AzureAD';    Module = 'AzureAD' }
}

# Modules the frontend knows how to check and install.
$script:KnownModules = @(
    'Microsoft.Graph', 'Microsoft.Graph.Beta', 'ExchangeOnlineManagement', 'PnP.PowerShell',
    'Microsoft.Online.SharePoint.PowerShell', 'MicrosoftTeams', 'MSOnline', 'AzureAD'
)

# Verb-Noun pairs that change tenant state. Deliberately limited to M365 nouns so
# New-Object / Add-Member / Set-Location do not count.
$script:ModifyPattern = '(?i)\b(Set|Remove|New|Add|Update|Grant|Revoke|Disable|Enable|Clear|Reset|Move|Restore)-(Mg|Mailbox|PnP|Team|CsTeams|Cs|Distribution|Unified|SPO|Recipient|Inbox|Calendar|Msol|AzureAD|Compliance|Retention|User|Group|Transport|Mail|RoleGroup|ManagementRole|OrganizationConfig|App|CASMailbox|Contact|Federated|Organization)\w*'

$script:SecretPattern = '(?i)(password|passwd|pwd|secret)'
$script:FilePattern   = '(?i)(csv|file|path|html)$|^(import|input)|csvpath|filepath|template'
$script:FolderPattern = '(?i)(folder|directory|dir|outputpath|logpath|exportpath)$'

function Get-AdKnownModules { , $script:KnownModules }

function Read-AdMetadataCsv {
    param([string]$RepoRoot)
    $map = @{}
    $csv = Join-Path $RepoRoot 'ScriptMetadata.csv'
    if (Test-Path -LiteralPath $csv) {
        foreach ($row in (Import-Csv -LiteralPath $csv -Encoding UTF8)) {
            if ($row.folderName) { $map[$row.folderName.Trim()] = $row }
        }
    }
    $map
}

function Get-AdHeaderInfo {
    # Parses the standard o365reports header comment:
    #   Name: ... / Script Highlights: 1. ... / For detailed script execution: URL
    param([string]$Text)
    $info = [ordered]@{ Title = $null; Highlights = @(); DocsUrl = $null; Version = $null }
    $m = [regex]::Match($Text, '(?s)<#(.*?)#>')
    if (-not $m.Success -or $m.Index -gt 400) { return $info }
    $header = $m.Groups[1].Value
    $name = [regex]::Match($header, '(?im)^\s*Name\s*:\s*(.+?)\s*$')
    if ($name.Success) { $info.Title = $name.Groups[1].Value }
    $ver = [regex]::Match($header, '(?im)^\s*Version\s*:\s*(.+?)\s*$')
    if ($ver.Success) { $info.Version = $ver.Groups[1].Value }
    $url = [regex]::Match($header, '(?is)For detailed.*?(https?://\S+)')
    if (-not $url.Success) { $url = [regex]::Match($header, '(?i)https?://(o365reports|blog\.admindroid)\S+') }
    if ($url.Success) { $info.DocsUrl = ($url.Groups[$url.Groups.Count - 1].Value).TrimEnd('.', ')', ',') }
    $hl = [regex]::Match($header, '(?is)Script Highlights\s*:?\s*~*\s*(.*?)(For detailed|={5,}|Change Log|$)')
    if ($hl.Success) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($hl.Groups[1].Value -split "`r?`n")) {
            $t = $line.Trim()
            if (-not $t -or $t -match '^~+$') { continue }
            if ($t -match '^\d+\s*[.)]\s*(.*)$') { $lines.Add($Matches[1]) }
            elseif ($lines.Count -gt 0) { $lines[$lines.Count - 1] = $lines[$lines.Count - 1] + ' ' + $t }
            else { $lines.Add($t) }
        }
        $info.Highlights = $lines.ToArray()
    }
    $info
}

function Get-AdReadmeSummary {
    param([string]$Folder)
    $readme = Join-Path $Folder 'README.md'
    if (-not (Test-Path -LiteralPath $readme)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($readme)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#') -or $t.StartsWith('*') -or $t.StartsWith('!') -or $t.StartsWith('<')) { continue }
        return ([regex]::Replace($t, '\[([^\]]+)\]\([^)]+\)', '$1'))
    }
    $null
}

function Get-AdScriptCatalog {
    <#
    .SYNOPSIS
    Lists every runnable .ps1 in the repo with lightweight metadata (text scan only;
    parameters are parsed on demand by Get-AdScriptParameters).
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
    $meta = Read-AdMetadataCsv -RepoRoot $RepoRoot
    $skipDirs = @('AdminDeck', '.git', '.github', '.claude')
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in (Get-ChildItem -LiteralPath $RepoRoot -Filter *.ps1 -File)) { $files.Add($f) }
    foreach ($d in (Get-ChildItem -LiteralPath $RepoRoot -Directory)) {
        if ($skipDirs -contains $d.Name) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $d.FullName -Filter *.ps1 -File -Recurse)) { $files.Add($f) }
    }

    $byFolder = $files | Group-Object { $_.DirectoryName } -AsHashTable -AsString

    foreach ($file in $files) {
        $folder = $file.DirectoryName
        $folderName = Split-Path $folder -Leaf
        $atRoot = ($folder.TrimEnd('\', '/') -eq $RepoRoot.TrimEnd('\', '/'))
        $text = [IO.File]::ReadAllText($file.FullName)
        $header = Get-AdHeaderInfo -Text $text
        $row = $null
        if (-not $atRoot -and $meta.ContainsKey($folderName)) { $row = $meta[$folderName] }

        $siblings = @($byFolder[$folder]).Count
        if ($atRoot) { $name = $file.BaseName }
        elseif ($siblings -gt 1) { $name = '{0} ({1})' -f $folderName, $file.Name }
        else { $name = $folderName }

        $services = New-Object System.Collections.Generic.List[string]
        $modules = New-Object System.Collections.Generic.List[string]
        foreach ($k in $script:ConnectMap.Keys) {
            if ($text -match ('(?i)\b' + [regex]::Escape($k) + '\b')) {
                $services.Add($script:ConnectMap[$k].Service)
                $mod = $script:ConnectMap[$k].Module
                if ($mod -eq 'Microsoft.Graph' -and $text -match '(?i)Microsoft\.Graph\.Beta') { $mod = 'Microsoft.Graph.Beta' }
                if (-not $modules.Contains($mod)) { $modules.Add($mod) }
            }
        }

        if ($row) {
            $area = $row.service; $category = $row.filter; $description = $row.description; $keywords = $row.weightedKeywords
        } else {
            $area = 'Other'
            $first = ($folderName -split '\s+')[0]
            if ($first -eq 'Audit') { $category = 'Auditing' }
            elseif ($name -match '(?i)report|^(export|get|find|list|check)\b') { $category = 'Reporting' }
            else { $category = 'Management & Automation' }
            $description = $null; $keywords = ''
        }
        if (-not $description) { $description = Get-AdReadmeSummary -Folder $folder }
        if (-not $description -and $header.Highlights.Count) { $description = $header.Highlights[0] }

        # Ignore comments and string literals: audit scripts list operation names like 'Add-MailboxPermission'.
        $code = [regex]::Replace($text, '(?s)<#.*?#>|#[^\r\n]*|''[^''\r\n]*''|"[^"\r\n]*"', '')
        $modifies = [regex]::IsMatch($code, $script:ModifyPattern) -or ($category -eq 'Management & Automation')
        $writesToScriptRoot = $text -match '(?i)\$PSScriptRoot\\'
        $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')

        [pscustomobject]@{
            Id                 = $relative
            Name               = $name
            Title              = $(if ($header.Title) { $header.Title } else { $name })
            Path               = $file.FullName
            Folder             = $folder
            FolderName         = $folderName
            Area               = $area
            Category           = $category
            Description        = $description
            Highlights         = $header.Highlights
            DocsUrl            = $header.DocsUrl
            Version            = $header.Version
            Services           = $services.ToArray()
            Modules            = $modules.ToArray()
            Modifies           = [bool]$modifies
            WritesToScriptRoot = [bool]$writesToScriptRoot
            SearchText         = (@($name, $header.Title, $description, $keywords, ($services -join ' '), ($header.Highlights -join ' ')) -join ' ').ToLowerInvariant()
        }
    }
}

function Get-AdParameterKind {
    param([string]$Name, [string]$TypeName, [string[]]$Choices)
    $t = $TypeName.ToLowerInvariant() -replace '^system\.', ''
    if ($t -eq 'switch' -or $t -eq 'switchparameter' -or $t -eq 'management.automation.switchparameter') { return 'Switch' }
    if ($t -eq 'bool' -or $t -eq 'boolean') { return 'Bool' }
    if ($Choices -and $Choices.Count) { return 'Choice' }
    if ($t -match 'datetime') { return 'Date' }
    if ($t -match '^(nullable\[)?(int|int32|int64|long|decimal|double|single|float|uint32|byte)\]?$') { return 'Number' }
    if ($t -match 'securestring' -or ($t -eq 'string' -and $Name -match $script:SecretPattern)) { return 'Secret' }
    if ($t -match '\[\]$' -or $t -eq 'array' -or $t -eq 'collections.arraylist') { return 'List' }
    if ($t -eq 'string' -or $t -eq '' -or $t -eq 'object') {
        if ($Name -match $script:FolderPattern) { return 'Folder' }
        if ($Name -match $script:FilePattern -and $Name -notmatch '(?i)url|relative|name$|deletedby') { return 'File' }
        if ($t -eq 'object') { return 'Raw' }
        return 'Text'
    }
    if ($t -match 'pscredential') { return 'Raw' }
    'Text'
}

function Get-AdScriptParameters {
    <#
    .SYNOPSIS
    Parses a script with the PowerShell AST and describes each parameter in its param() block.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $result = [ordered]@{ Parameters = @(); ParseErrors = @(); ParameterSets = @() }
    if ($errors -and $errors.Count) { $result.ParseErrors = @($errors | ForEach-Object { 'Line {0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) }
    if (-not $ast.ParamBlock) { return [pscustomobject]$result }

    # Comments keyed by line so "[int]$Days, #Pass value as 30" yields a hint.
    $commentsByLine = @{}
    foreach ($tok in $tokens) {
        if ($tok.Kind -eq 'Comment' -and -not $tok.Text.StartsWith('<#')) {
            $commentsByLine[$tok.Extent.StartLineNumber] = $tok.Text.TrimStart('#').Trim()
        }
    }

    $sets = New-Object System.Collections.Generic.List[string]
    $params = foreach ($p in $ast.ParamBlock.Parameters) {
        $name = $p.Name.VariablePath.UserPath
        $typeName = ''
        $choices = @()
        $mandatorySets = New-Object System.Collections.Generic.List[string]
        $paramSets = New-Object System.Collections.Generic.List[string]
        $help = $null
        foreach ($attr in $p.Attributes) {
            if ($attr -is [System.Management.Automation.Language.TypeConstraintAst]) {
                $typeName = $attr.TypeName.FullName
            } elseif ($attr -is [System.Management.Automation.Language.AttributeAst]) {
                $an = $attr.TypeName.Name
                if ($an -match '^(Parameter|System\.Management\.Automation\.Parameter)$') {
                    $isMandatory = $false; $setName = $null
                    foreach ($na in $attr.NamedArguments) {
                        switch -Regex ($na.ArgumentName) {
                            '^Mandatory$' {
                                if ($na.ExpressionOmitted) { $isMandatory = $true }
                                else { $isMandatory = ($na.Argument.Extent.Text -match '(?i)^\$?true$|^1$') }
                            }
                            '^ParameterSetName$' { $setName = $na.Argument.Extent.Text.Trim('''', '"') }
                            '^HelpMessage$' { $help = $na.Argument.Extent.Text.Trim('''', '"') }
                        }
                    }
                    if ($setName) { $paramSets.Add($setName); if (-not $sets.Contains($setName)) { $sets.Add($setName) } }
                    if ($isMandatory) { $mandatorySets.Add($(if ($setName) { $setName } else { '*' })) }
                } elseif ($an -match '^ValidateSet$') {
                    $choices = @($attr.PositionalArguments | ForEach-Object { $_.Extent.Text.Trim().Trim('''', '"') })
                }
            }
        }
        if (-not $typeName -and $p.StaticType -and $p.StaticType -ne [object]) { $typeName = $p.StaticType.Name }

        $default = $null
        if ($p.DefaultValue) {
            $default = $p.DefaultValue.Extent.Text
            if ($default -match '^\$null$') { $default = $null }
        }
        $hint = $help
        $endLine = $p.Extent.EndLineNumber
        if (-not $hint -and $commentsByLine.ContainsKey($endLine)) { $hint = $commentsByLine[$endLine] }

        $kind = Get-AdParameterKind -Name $name -TypeName $typeName -Choices $choices
        [pscustomobject]@{
            Name          = $name
            TypeName      = $typeName
            Kind          = $kind
            Choices       = $choices
            Default       = $default
            Hint          = $hint
            Mandatory     = ($mandatorySets.Count -gt 0)
            AlwaysRequired = ($mandatorySets -contains '*') -and ($paramSets.Count -eq 0)
            MandatorySets = $mandatorySets.ToArray()
            ParameterSets = $paramSets.ToArray()
        }
    }
    $result.Parameters = @($params)
    $result.ParameterSets = $sets.ToArray()
    [pscustomobject]$result
}

function ConvertTo-AdQuoted {
    param([string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

function Test-AdParameterValue {
    <# Returns $null when the value is acceptable for the parameter kind, else an error message. #>
    param([Parameter(Mandatory)]$Parameter, $Value)
    if ($null -eq $Value -or ($Value -is [string] -and $Value.Trim() -eq '')) { return $null }
    switch ($Parameter.Kind) {
        'Number' { if ("$Value".Trim() -notmatch '^-?\d+(\.\d+)?$') { return "$($Parameter.Name) must be a number." } }
        'Date' {
            $d = [datetime]::MinValue
            if (-not [datetime]::TryParse("$Value", [ref]$d)) { return "$($Parameter.Name) is not a valid date." }
        }
        'Choice' { if ($Parameter.Choices -notcontains "$Value") { return "$($Parameter.Name) must be one of: $($Parameter.Choices -join ', ')." } }
    }
    $null
}

function ConvertTo-AdInvocation {
    <#
    .SYNOPSIS
    Builds the call for a script from form values.
    .OUTPUTS
    Command  - text to run, with secrets referenced as $env:ADECK_SECRET_n
    Display  - same text with secrets masked (safe to show / log)
    Secrets  - hashtable of env var name -> secret value, to set on the child process only
    Errors   - validation messages
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [object[]]$Parameters = @(),
        [hashtable]$Values = @{},
        [string]$ExtraArguments
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $display = New-Object System.Collections.Generic.List[string]
    $secrets = @{}
    $errors = New-Object System.Collections.Generic.List[string]
    $parts.Add('& ' + (ConvertTo-AdQuoted $ScriptPath)); $display.Add($parts[0])
    $n = 0

    foreach ($p in $Parameters) {
        if (-not $Values.ContainsKey($p.Name)) { continue }
        $v = $Values[$p.Name]
        if ($null -eq $v) { continue }
        $err = Test-AdParameterValue -Parameter $p -Value $v
        if ($err) { $errors.Add($err); continue }
        $flag = '-' + $p.Name
        $arg = $null; $shown = $null
        switch ($p.Kind) {
            'Switch' { if ([bool]$v) { $parts.Add($flag); $display.Add($flag) }; continue }
            'Bool' {
                if ("$v" -eq '') { continue }
                $b = if ("$v" -match '(?i)^(true|1|yes)$') { '$true' } else { '$false' }
                $parts.Add("${flag}:$b"); $display.Add("${flag}:$b"); continue
            }
            'Number' { $arg = "$v".Trim() }
            'Raw' { $arg = "$v".Trim() }
            'List' {
                $items = @("$v" -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if (-not $items.Count) { continue }
                $arg = ($items | ForEach-Object { ConvertTo-AdQuoted $_ }) -join ','
            }
            'Secret' {
                if ("$v" -eq '') { continue }
                $n++
                $envName = "ADECK_SECRET_$n"
                $secrets[$envName] = "$v"
                $arg = "`$env:$envName"; $shown = "'********'"
                if ($p.TypeName -match '(?i)securestring') {
                    $arg = "(ConvertTo-SecureString `$env:$envName -AsPlainText -Force)"
                }
            }
            default {
                if ("$v".Trim() -eq '') { continue }
                $arg = ConvertTo-AdQuoted ("$v".Trim())
            }
        }
        if ($null -eq $arg -or $arg -eq '') { continue }
        $parts.Add("$flag $arg")
        $display.Add("$flag $(if ($shown) { $shown } else { $arg })")
    }

    foreach ($p in $Parameters) {
        if (-not $p.AlwaysRequired) { continue }
        $v = $Values[$p.Name]
        if ($null -eq $v -or ("$v".Trim() -eq '') -or ($p.Kind -eq 'Switch' -and -not [bool]$v)) {
            $errors.Add("$($p.Name) is required.")
        }
    }

    if ($ExtraArguments -and $ExtraArguments.Trim()) {
        $parts.Add($ExtraArguments.Trim()); $display.Add($ExtraArguments.Trim())
    }

    [pscustomobject]@{
        Command = ($parts -join ' ')
        Display = ($display -join ' ')
        Secrets = $secrets
        Errors  = $errors.ToArray()
    }
}

function New-AdLaunchScript {
    <#
    .SYNOPSIS
    Wraps an invocation into the full text run in the child console: window title,
    working folder, secret hand-off from env vars, optional transcript.
    #>
    param(
        [Parameter(Mandatory)]$Invocation,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [switch]$Transcript
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('$Host.UI.RawUI.WindowTitle = ' + (ConvertTo-AdQuoted "AdminDeck - $Title"))
    [void]$sb.AppendLine('Set-Location -LiteralPath ' + (ConvertTo-AdQuoted $WorkingDirectory))
    $cmd = $Invocation.Command
    $i = 0
    foreach ($k in @($Invocation.Secrets.Keys)) {
        $i++
        # Copy into a local and drop the env var so nothing the script spawns inherits it.
        [void]$sb.AppendLine("`$__adeck_s$i = `$env:$k; Remove-Item -LiteralPath Env:\$k -ErrorAction SilentlyContinue")
        $cmd = $cmd.Replace("`$env:$k", "`$__adeck_s$i")
    }
    [void]$sb.AppendLine('Write-Host ' + (ConvertTo-AdQuoted ('> ' + $Invocation.Display)) + ' -ForegroundColor DarkCyan')
    if ($Transcript) {
        $log = Join-Path $WorkingDirectory ('transcript_{0:yyyy-MM-dd_HH-mm-ss}.txt' -f (Get-Date))
        [void]$sb.AppendLine('Start-Transcript -LiteralPath ' + (ConvertTo-AdQuoted $log) + ' | Out-Null')
    }
    [void]$sb.AppendLine('try {')
    [void]$sb.AppendLine("    $cmd")
    [void]$sb.AppendLine('} catch { Write-Host $_ -ForegroundColor Red } finally {')
    if ($Transcript) { [void]$sb.AppendLine('    try { Stop-Transcript | Out-Null } catch {}') }
    [void]$sb.AppendLine('    Write-Host ""; Write-Host ("AdminDeck: finished. Output folder: " + ' + (ConvertTo-AdQuoted $WorkingDirectory) + ') -ForegroundColor Green')
    [void]$sb.AppendLine('}')
    $sb.ToString()
}

function Get-AdSafeFolderName {
    param([string]$Name)
    $invalid = [regex]::Escape(-join [IO.Path]::GetInvalidFileNameChars())
    ($Name -replace "[$invalid]", '_' -replace '\s+', ' ').Trim().TrimEnd('.')
}

Export-ModuleMember -Function Get-AdScriptCatalog, Get-AdScriptParameters, ConvertTo-AdInvocation, `
    New-AdLaunchScript, Test-AdParameterValue, Get-AdKnownModules, Get-AdSafeFolderName, ConvertTo-AdQuoted, Get-AdHeaderInfo
