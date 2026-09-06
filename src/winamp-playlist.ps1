#requires -version 5.1
<#
    winamp-playlist.ps1

    Worker invoked (hidden, via launch-hidden.vbs) from the Explorer
    right-click menu. Builds an M3U8 playlist from the selected files/folders,
    shows a small progress dialog while it works, and hands the playlist to
    WACUP or Winamp.

      - Exactly one folder selected -> playlist saved *inside* that folder,
        named after it, with paths relative to the playlist (portable if the
        folder moves).
      - Anything else (files, multiple folders, a mix) -> playlist saved to
        "Documents\Winamp Playlists\Playlist_<timestamp>.m3u8" with absolute
        paths.

    Explorer does not reliably honor MultiSelectModel=Player for per-extension
    verbs: with N files selected it may launch this script N times, once per
    file. Two defenses:
      1. A named mutex plus a recent-run marker file collapse the burst - only
         the first process does any work, the rest exit instantly and silently.
      2. The surviving process reads the real, full selection straight from the
         Explorer window via Shell COM, so it sees all N files even though its
         own command line may have carried only one.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Paths
)

$ErrorActionPreference = 'Stop'

$AudioExtensions = @('.mp3', '.flac', '.wav', '.m4a', '.ogg', '.wma', '.aac', '.opus')
$AudioExtSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($e in $AudioExtensions) { [void]$AudioExtSet.Add($e) }

function Show-Message {
    param([string] $Text, [string] $Icon = 'Information')
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Text, 'Winamp Playlist Maker', 'OK', $Icon) | Out-Null
}

# ---------------------------------------------------------- progress dialog ----

function New-ProgressUI {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Winamp Playlist Maker'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.ControlBox = $false
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.ClientSize = New-Object System.Drawing.Size(380, 92)

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(348, 20)
    $label.Text = 'Starting...'
    $form.Controls.Add($label)

    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(16, 46)
    $bar.Size = New-Object System.Drawing.Size(348, 22)
    $bar.Style = 'Marquee'
    $bar.MarqueeAnimationSpeed = 25
    $form.Controls.Add($bar)

    $form.Show()
    $form.Refresh()
    return [pscustomobject]@{ Form = $form; Label = $label; Bar = $bar }
}

function Set-Progress {
    param($UI, [string] $Text)
    if (-not $UI) { return }
    $UI.Label.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-ProgressUI {
    param($UI)
    if (-not $UI) { return }
    $UI.Form.Close()
    $UI.Form.Dispose()
}

# ------------------------------------------------------------------ helpers ----

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

# ---------------------------------------- selection recovery & burst control ----

function Get-BatchKey {
    param([string] $Seed)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed.ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 20)
}

# Reads the full current selection from whichever open Explorer window contains
# the right-clicked item. Returns $null if it can't be determined.
function Get-ExplorerSelection {
    param([string] $MustContain)
    $result = $null
    $shellApp = $null
    try {
        $shellApp = New-Object -ComObject Shell.Application
        foreach ($window in @($shellApp.Windows())) {
            try {
                $items = $window.Document.SelectedItems()
                if (-not $items -or $items.Count -eq 0) { continue }
                $paths = New-Object System.Collections.Generic.List[string]
                foreach ($item in @($items)) {
                    if ($item.Path) { $paths.Add($item.Path) }
                }
                $hasTarget = $false
                foreach ($p in $paths) {
                    if ([string]::Equals($p, $MustContain, [StringComparison]::OrdinalIgnoreCase)) { $hasTarget = $true; break }
                }
                if ($hasTarget -and (-not $result -or $paths.Count -gt $result.Count)) { $result = $paths }
            } catch { }
        }
    } catch { }
    finally {
        if ($shellApp) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellApp) }
    }
    if ($result) { return $result.ToArray() }
    return $null
}

# --------------------------------------------------------------------- main ----

$argPaths = @()
foreach ($p in @($Paths)) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $t = $p.Trim().Trim('"')
    if ($t -match '^%\d+$') { continue }
    if (Test-Path -LiteralPath $t) {
        $argPaths += (Resolve-Path -LiteralPath $t).ProviderPath
    }
}
if ($argPaths.Count -eq 0) {
    Show-Message -Text 'No files were passed from Explorer.' -Icon 'Warning'
    exit 1
}

$batchDir = if (Test-Path -LiteralPath $argPaths[0] -PathType Container) { $argPaths[0] } else { Split-Path -Parent $argPaths[0] }
$batchKey = Get-BatchKey $batchDir

# Burst collapsing: the mutex stops the simultaneous duplicates, the marker
# file stops stragglers that start after the winner already finished.
$markerDir = Join-Path $env:TEMP 'WinampPlaylistMaker'
[System.IO.Directory]::CreateDirectory($markerDir) | Out-Null
$marker = Join-Path $markerDir "lastrun_$batchKey.txt"
if (Test-Path -LiteralPath $marker) {
    $age = (Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime
    if ($age.TotalSeconds -ge 0 -and $age.TotalSeconds -lt 5) { exit 0 }
}

$mutex = New-Object System.Threading.Mutex($false, "Local\WinampPlaylistMaker_$batchKey")
if (-not $mutex.WaitOne(0)) { exit 0 }

$ui = $null
try {
    [System.IO.File]::WriteAllText($marker, (Get-Date -Format 'o'))

    # Recover the complete selection from the Explorer window itself - the
    # command line may carry only one of N selected files.
    $selection = Get-ExplorerSelection -MustContain $argPaths[0]
    $effective = if ($selection -and $selection.Count -gt $argPaths.Count) { $selection } else { $argPaths }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $inputPaths = @()
    foreach ($p in $effective) { if ($seen.Add($p)) { $inputPaths += $p } }

    $ui = New-ProgressUI

    # ------------------------------------------------------------ collect ----

    $isSingleFolder = $inputPaths.Count -eq 1 -and (Test-Path -LiteralPath $inputPaths[0] -PathType Container)
    $singleFolderPath = if ($isSingleFolder) { $inputPaths[0] } else { $null }

    $files = New-Object System.Collections.Generic.List[string]
    foreach ($p in $inputPaths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        if (Test-Path -LiteralPath $p -PathType Container) {
            Set-Progress $ui ('Scanning ' + (Split-Path $p -Leaf) + '...')
            $n = 0
            foreach ($f in [System.IO.Directory]::EnumerateFiles($p, '*', [System.IO.SearchOption]::AllDirectories)) {
                if ($AudioExtSet.Contains([System.IO.Path]::GetExtension($f))) { $files.Add($f) }
                if ((++$n % 200) -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
            }
        } elseif ($AudioExtSet.Contains([System.IO.Path]::GetExtension($p))) {
            $files.Add($p)
        }
    }

    if ($files.Count -eq 0) {
        Close-ProgressUI $ui; $ui = $null
        Show-Message -Text 'No supported audio files (mp3, flac, wav, m4a, ogg, wma, aac, opus) were found in that selection.' -Icon 'Warning'
        exit 1
    }

    Set-Progress $ui ('Sorting ' + $files.Count + ' track' + $(if ($files.Count -ne 1) { 's' }) + '...')
    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $deduped = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) { if ($unique.Add($f)) { $deduped.Add($f) } }
    $sorted = $deduped | Sort-Object { Get-NaturalSortKey $_ }

    # -------------------------------------------------------------- write ----

    Set-Progress $ui 'Writing playlist...'

    # If every track sits in one folder, the playlist belongs next to the
    # music (named after the folder, relative paths). Documents is only the
    # fallback for selections that span multiple folders.
    $commonDir = $null
    if ($isSingleFolder) {
        $commonDir = $singleFolderPath
    } else {
        $commonDir = Split-Path -Parent $sorted[0]
        foreach ($f in $sorted) {
            if (-not [string]::Equals((Split-Path -Parent $f), $commonDir, [StringComparison]::OrdinalIgnoreCase)) {
                $commonDir = $null; break
            }
        }
    }

    if ($commonDir) {
        $baseDir = $commonDir
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

    # ----------------------------------------------------------- hand off ----

    $player = Find-PlayerExe

    if ($player) {
        # No /ADD: opening the playlist replaces what's loaded and starts
        # playing it. /ADD only appends silently to the end of the current
        # playlist without raising the window - it looks like nothing happened.
        Start-Process -FilePath $player -ArgumentList @("`"$playlistPath`"")
        Set-Progress $ui ('Done - ' + $sorted.Count + ' track' + $(if ($sorted.Count -ne 1) { 's' }) + ', playing in ' + [System.IO.Path]::GetFileNameWithoutExtension($player).ToUpper() + '.')
        Start-Sleep -Milliseconds 1500
        Close-ProgressUI $ui; $ui = $null
    } else {
        Close-ProgressUI $ui; $ui = $null
        Show-Message -Text "Playlist saved:`n$playlistPath`n`nWACUP/Winamp wasn't found automatically - open the file from there."
    }
}
catch {
    if ($ui) { Close-ProgressUI $ui; $ui = $null }
    Show-Message -Text ("Failed:`n`n" + $_.Exception.Message) -Icon 'Error'
    exit 1
}
finally {
    if ($ui) { Close-ProgressUI $ui }
    [void]$mutex.ReleaseMutex()
    $mutex.Dispose()
}
