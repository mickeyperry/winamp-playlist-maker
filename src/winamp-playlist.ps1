#requires -version 5.1
<#
    winamp-playlist.ps1

    Worker invoked from the Explorer right-click menu. Builds an M3U8 playlist
    from the selected files/folders and hands it to WACUP or Winamp.

      - Exactly one folder selected -> playlist saved *inside* that folder,
        named after it, with paths relative to the playlist (portable if the
        folder moves).
      - Anything else (files, multiple folders, a mix) -> playlist saved to
        "Documents\Winamp Playlists\Playlist_<timestamp>.m3u8" with absolute
        paths.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]] $Paths
)

$ErrorActionPreference = 'Stop'

$AudioExtensions = @('.mp3', '.flac', '.wav', '.m4a', '.ogg', '.wma', '.aac', '.opus')

function Show-Message {
    param([string] $Text, [string] $Icon = 'Information')
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Text, 'Winamp Playlist Maker', 'OK', $Icon) | Out-Null
}

# Zero-pads embedded digit runs ("Track 2" -> "Track 0000000002") so Sort-Object
# orders "Track 2" before "Track 10" instead of alphabetically.
function Get-NaturalSortKey {
    param([string] $Value)
    [regex]::Replace($Value, '\d+', { param($m) $m.Value.PadLeft(10, '0') })
}

# .NET Framework 4.x (what Windows PowerShell 5.1 runs on) has no
# [System.IO.Path]::GetRelativePath - build it from a Uri instead.
function Get-RelativePath {
    param([string] $BaseDir, [string] $TargetPath)
    $baseUri = New-Object System.Uri(($BaseDir.TrimEnd('\', '/') + '\'))
    $targetUri = New-Object System.Uri($TargetPath)
    $rel = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString())
    return ($rel -replace '/', '\')
}

function Find-PlayerExe {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    foreach ($rel in @('WACUP\wacup.exe', 'Winamp\winamp.exe')) {
        foreach ($root in $roots) {
            $candidate = Join-Path $root $rel
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    $appPathKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\wacup.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\wacup.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\winamp.exe',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\winamp.exe'
    )
    foreach ($k in $appPathKeys) {
        if (Test-Path -LiteralPath $k) {
            $val = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).'(default)'
            if ($val -and (Test-Path -LiteralPath $val)) { return $val }
        }
    }
    return $null
}

# ------------------------------------------------------------ collect files ----

$isSingleFolder = $Paths.Count -eq 1 -and (Test-Path -LiteralPath $Paths[0] -PathType Container)
$singleFolderPath = if ($isSingleFolder) { (Resolve-Path -LiteralPath $Paths[0]).ProviderPath } else { $null }

$files = New-Object System.Collections.Generic.List[string]
foreach ($p in $Paths) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (Test-Path -LiteralPath $p -PathType Container) {
        Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $AudioExtensions -contains $_.Extension.ToLowerInvariant() } |
            ForEach-Object { $files.Add($_.FullName) }
    } elseif ($AudioExtensions -contains ([System.IO.Path]::GetExtension($p).ToLowerInvariant())) {
        $files.Add((Resolve-Path -LiteralPath $p).ProviderPath)
    }
}

if ($files.Count -eq 0) {
    Show-Message -Text 'No supported audio files (mp3, flac, wav, m4a, ogg, wma, aac, opus) were found in that selection.' -Icon 'Warning'
    exit 1
}

$sorted = $files | Sort-Object { Get-NaturalSortKey $_ } -Unique

# ------------------------------------------------------------ write playlist ----

if ($isSingleFolder) {
    $baseDir = $singleFolderPath
    $playlistPath = Join-Path $baseDir ((Split-Path $baseDir -Leaf) + '.m3u8')
} else {
    $baseDir = $null
    $playlistsDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Winamp Playlists'
    [System.IO.Directory]::CreateDirectory($playlistsDir) | Out-Null
    $playlistPath = Join-Path $playlistsDir ('Playlist_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.m3u8')
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('#EXTM3U')
foreach ($f in $sorted) {
    $lines.Add('#EXTINF:-1,' + [System.IO.Path]::GetFileNameWithoutExtension($f))
    if ($baseDir) { $lines.Add((Get-RelativePath -BaseDir $baseDir -TargetPath $f)) }
    else { $lines.Add($f) }
}
[System.IO.File]::WriteAllLines($playlistPath, $lines, (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ hand off ----

$player = Find-PlayerExe
if ($player) {
    Start-Process -FilePath $player -ArgumentList @('/ADD', "`"$playlistPath`"")
} else {
    Show-Message -Text "Playlist saved:`n$playlistPath`n`nWACUP/Winamp wasn't found automatically - open the file from there."
}
