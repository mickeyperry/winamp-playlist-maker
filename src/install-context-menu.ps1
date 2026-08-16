#requires -version 5.1
<#
    install-context-menu.ps1

    Adds "Add to Winamp Playlist" (audio files) and "Create Winamp Playlist"
    (folders) to the Explorer right-click menu, for the current user only.

    Registry layout, one verb key per audio extension plus one for folders:
      HKCU:\Software\Classes\SystemFileAssociations\.mp3\shell\WinampPlaylistMaker
      HKCU:\Software\Classes\Directory\shell\WinampPlaylistMaker
    Each has MultiSelectModel=Player, so selecting several files/folders and
    invoking the verb runs the worker once with every selected path, instead
    of once per item.

    Re-running this script is safe; it rewrites the keys in place.
#>
[CmdletBinding()]
param(
    # Where winamp-playlist.ps1 lives. Defaults to this script's own folder.
    [string] $ScriptPath
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated inside a param() default, so resolve it here.
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) {
        $here = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    $ScriptPath = Join-Path $here 'winamp-playlist.ps1'
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Worker script not found: $ScriptPath"
}
# .ProviderPath, not .Path: for a UNC or mapped location .Path comes back
# provider-qualified, and powershell.exe -File cannot open that - the console
# window Explorer opens would just close instantly with no message.
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
if ($ScriptPath -notmatch '^([A-Za-z]:\\|\\\\)') {
    throw "Refusing to register a path Explorer cannot launch: $ScriptPath"
}

$AudioExtensions = @('.mp3', '.flac', '.wav', '.m4a', '.ogg', '.wma', '.aac', '.opus')
$VerbName = 'WinampPlaylistMaker'

function Find-PlayerExe {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    foreach ($rel in @('WACUP\wacup.exe', 'Winamp\winamp.exe')) {
        foreach ($root in $roots) {
            $candidate = Join-Path $root $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    return $null
}

$player = Find-PlayerExe
$icon = if ($player) { "$player,0" } else { $null }

# Explorer runs this command as a 64-bit process, so the literal System32 path
# is the right one to write. Fall back to the bare name if that copy is missing.
$psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

# %1 is the right-clicked item's path. With MultiSelectModel=Player (set below)
# Explorer expands it to every selected item, not just the first.
$command = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" %1"

function Register-Verb {
    param([string] $KeyPath, [string] $Label)

    Remove-Item -LiteralPath $KeyPath -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -Path $KeyPath -Force
    Set-ItemProperty -Path $KeyPath -Name '(Default)' -Value $Label
    if ($icon) { New-ItemProperty -Path $KeyPath -Name 'Icon' -Value $icon -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $KeyPath -Name 'MultiSelectModel' -Value 'Player' -PropertyType String -Force | Out-Null

    $cmdKey = Join-Path $KeyPath 'command'
    $null = New-Item -Path $cmdKey -Force
    Set-ItemProperty -Path $cmdKey -Name '(Default)' -Value $command
}

Write-Host ''
Write-Host '  Installing Winamp Playlist Maker context menu' -ForegroundColor White
Write-Host '  ----------------------------------------------' -ForegroundColor DarkGray
Write-Host "  Worker : $ScriptPath"
Write-Host "  Player : $(if ($player) { $player } else { 'not found yet - install WACUP or Winamp' })"
Write-Host ''

foreach ($ext in $AudioExtensions) {
    $key = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$VerbName"
    Register-Verb -KeyPath $key -Label 'Add to Winamp Playlist'
    Write-Host "  + $ext" -ForegroundColor Green
}

$dirKey = "HKCU:\Software\Classes\Directory\shell\$VerbName"
Register-Verb -KeyPath $dirKey -Label 'Create Winamp Playlist'
Write-Host '  + folders' -ForegroundColor Green

Write-Host ''
Write-Host '  Installed for the current user.' -ForegroundColor Green
Write-Host ''
Write-Host '  On Windows 11 the entry lives under "Show more options"' -ForegroundColor DarkGray
Write-Host '  in the right-click menu (or press Shift+F10).' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  To remove it later, run Uninstall.cmd' -ForegroundColor DarkGray
Write-Host ''
