<# 
.SYNOPSIS
Merges shared and personal VS Code settings, keybindings, and Vim RC files.

.DESCRIPTION
The script reads source files from shared and personal directories next to this
script by default, writes merged VS Code files into the absolute VS Code User
directory under $env:APPDATA, and writes the merged Vim RC to $HOME\.vimrc by
default.

Use -WhatIf to preview writes without changing files. Existing target files are
backed up unless -NoBackup is supplied.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SharedDir,
    [string]$PersonalDir,
    [string]$TargetUserDir,
    [string]$VimRcPath,
    [switch]$NoBackup
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    Split-Path -Parent $PSCommandPath
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($SharedDir)) {
    $SharedDir = Join-Path $ScriptDirectory 'shared'
}

if ([string]::IsNullOrWhiteSpace($PersonalDir)) {
    $PersonalDir = Join-Path $ScriptDirectory 'personal'
}

if ([string]::IsNullOrWhiteSpace($TargetUserDir)) {
    $TargetUserDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Code\User'
}

if ([string]::IsNullOrWhiteSpace($VimRcPath)) {
    $VimRcPath = Join-Path $HOME '.vimrc'
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-Lf {
    param([string]$Text)

    return $Text -replace "`r`n", "`n" -replace "`r", "`n"
}

function ConvertTo-Crlf {
    param([string]$Text)

    return ((ConvertTo-Lf $Text) -replace "`n", "`r`n")
}

function Read-OptionalText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Warning "Source file not found: $Path. Using empty content for this section."
        return ''
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    return [System.IO.File]::ReadAllText($resolvedPath, [System.Text.Encoding]::UTF8)
}

function Get-MatchingJsoncContainer {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [ValidateSet('{', '[')]
        [string]$OpenChar
    )

    $expectedOpen = [char]$OpenChar
    $depth = 0
    $start = -1
    $inString = $false
    $inLineComment = $false
    $inBlockComment = $false
    $escaped = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($char -eq "`n") {
                $inLineComment = $false
            }
            continue
        }

        if ($inBlockComment) {
            if ($char -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if ($inString) {
            if ($escaped) {
                $escaped = $false
            }
            elseif ($char -eq '\') {
                $escaped = $true
            }
            elseif ($char -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($char -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $i++
            continue
        }

        if ($char -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        if ($char -eq '"') {
            $inString = $true
            continue
        }

        if ($start -lt 0) {
            if ($char -eq $expectedOpen) {
                $start = $i
                $depth = 1
            }
            continue
        }

        if ($char -eq '{' -or $char -eq '[') {
            $depth++
        }
        elseif ($char -eq '}' -or $char -eq ']') {
            $depth--
            if ($depth -eq 0) {
                return [pscustomobject]@{
                    Start = $start
                    End   = $i
                    Inner = $Text.Substring($start + 1, $i - $start - 1)
                }
            }
        }
    }

    throw "Could not find a complete top-level '$OpenChar' JSONC container."
}

function Get-JsoncBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('{', '[')]
        [string]$OpenChar
    )

    $text = ConvertTo-Lf (Read-OptionalText $Path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }

    $container = Get-MatchingJsoncContainer -Text $text -OpenChar $OpenChar
    $body = (ConvertTo-Lf $container.Inner).Trim("`n")

    if ([string]::IsNullOrWhiteSpace($body)) {
        return ''
    }

    return Remove-TrailingComma $body
}

function Remove-TrailingComma {
    param([string]$Text)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ((ConvertTo-Lf $Text) -split "`n", -1)) {
        [void]$lines.Add($line)
    }

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $trimmedRight = $lines[$i].TrimEnd()
        if ($trimmedRight.Length -eq 0) {
            continue
        }

        if ($trimmedRight.EndsWith(',')) {
            $lines[$i] = $trimmedRight.Substring(0, $trimmedRight.Length - 1)
        }
        break
    }

    return (($lines -join "`n").Trim("`n"))
}

function Add-TrailingComma {
    param([string]$Text)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ((ConvertTo-Lf $Text) -split "`n", -1)) {
        [void]$lines.Add($line)
    }

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $trimmedRight = $lines[$i].TrimEnd()
        if ($trimmedRight.Length -eq 0) {
            continue
        }

        if (-not $trimmedRight.EndsWith(',')) {
            $lines[$i] = "$trimmedRight,"
        }
        break
    }

    return (($lines -join "`n").Trim("`n"))
}

function Get-BodyLines {
    param(
        [AllowEmptyString()]
        [string]$Body = ''
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        return @()
    }

    return ((ConvertTo-Lf $Body) -split "`n", -1)
}

function New-MergedJsonc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharedPath,
        [Parameter(Mandatory = $true)]
        [string]$PersonalPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Object', 'Array')]
        [string]$ContainerType
    )

    $openChar = if ($ContainerType -eq 'Object') { '{' } else { '[' }
    $closeChar = if ($ContainerType -eq 'Object') { '}' } else { ']' }
    $sharedBody = Get-JsoncBody -Path $SharedPath -OpenChar $openChar
    $personalBody = Get-JsoncBody -Path $PersonalPath -OpenChar $openChar

    if (-not [string]::IsNullOrWhiteSpace($sharedBody) -and -not [string]::IsNullOrWhiteSpace($personalBody)) {
        $sharedBody = Add-TrailingComma $sharedBody
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add($openChar)
    [void]$lines.Add('    // SHARED CONTENT START')
    foreach ($line in (Get-BodyLines -Body $sharedBody)) {
        [void]$lines.Add($line)
    }
    [void]$lines.Add('    // SHARED CONTENT END')
    [void]$lines.Add('    // PERSONAL CONTENT START')
    foreach ($line in (Get-BodyLines -Body $personalBody)) {
        [void]$lines.Add($line)
    }
    [void]$lines.Add('    // PERSONAL CONTENT END')
    [void]$lines.Add($closeChar)

    return ConvertTo-Crlf (($lines -join "`n") + "`n")
}

function New-MergedVimRc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharedPath,
        [Parameter(Mandatory = $true)]
        [string]$PersonalPath
    )

    $sharedBody = (ConvertTo-Lf (Read-OptionalText $SharedPath)).Trim("`n")
    $personalBody = (ConvertTo-Lf (Read-OptionalText $PersonalPath)).Trim("`n")

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('" SHARED CONTENT START')
    foreach ($line in (Get-BodyLines -Body $sharedBody)) {
        [void]$lines.Add($line)
    }
    [void]$lines.Add('" SHARED CONTENT END')
    [void]$lines.Add('" PERSONAL CONTENT START')
    foreach ($line in (Get-BodyLines -Body $personalBody)) {
        [void]$lines.Add($line)
    }
    [void]$lines.Add('" PERSONAL CONTENT END')

    return ConvertTo-Crlf (($lines -join "`n") + "`n")
}

function Backup-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($NoBackup -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.backup-$timestamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Host "Backed up $Path to $backupPath"
}

function Write-MergedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if ($PSCmdlet.ShouldProcess($Path, 'write merged settings file')) {
        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        Backup-ExistingFile -Path $Path
        [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
        Write-Host "Wrote $Path"
    }
}

$SharedDir = Resolve-FullPath $SharedDir
$PersonalDir = Resolve-FullPath $PersonalDir
$TargetUserDir = Resolve-FullPath $TargetUserDir
$VimRcPath = Resolve-FullPath $VimRcPath

$settingsContent = New-MergedJsonc `
    -SharedPath (Join-Path $SharedDir 'settings.json') `
    -PersonalPath (Join-Path $PersonalDir 'settings.json') `
    -ContainerType Object

$keybindingsContent = New-MergedJsonc `
    -SharedPath (Join-Path $SharedDir 'keybindings.json') `
    -PersonalPath (Join-Path $PersonalDir 'keybindings.json') `
    -ContainerType Array

$vimRcContent = New-MergedVimRc `
    -SharedPath (Join-Path $SharedDir 'vim.rc') `
    -PersonalPath (Join-Path $PersonalDir 'vim.rc')

Write-MergedFile -Path (Join-Path $TargetUserDir 'settings.json') -Content $settingsContent
Write-MergedFile -Path (Join-Path $TargetUserDir 'keybindings.json') -Content $keybindingsContent
Write-MergedFile -Path $VimRcPath -Content $vimRcContent
