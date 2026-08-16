#requires -version 5.1
<#
    winamp-playlist-maker installer.

    Works two ways:

    1. Web (nothing downloaded yet) - the repo is fetched to
       %LOCALAPPDATA%\Programs\winamp-playlist-maker and installed from there:

           irm https://raw.githubusercontent.com/mickeyperry/winamp-playlist-maker/main/install.ps1 | iex

    2. Local (you cloned or unzipped the repo) - the files are copied to that
       same folder and installed from there, so the menu keeps working after
       you delete the download. Add -InPlace to register the copy you are
       sitting in:

           powershell -ExecutionPolicy Bypass -File .\install.ps1 -InPlace

    Everything is per-user. No admin rights, nothing written outside HKCU
    and your own profile.
#>
[CmdletBinding()]
param(
    # Where to put the files in web mode.
    [string] $InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\winamp-playlist-maker'),

    # Register the scripts where they already sit instead of copying them to
    # $InstallDir. For working on a clone.
    [switch] $InPlace
)

$ErrorActionPreference = 'Stop'

$RepoOwner = 'mickeyperry'
$RepoName  = 'winamp-playlist-maker'
$RepoRef   = 'main'

# ---------------------------------------------------------------- output ----

function Write-Head {
    Write-Host ''
    Write-Host '  winamp-playlist-maker' -ForegroundColor White
    Write-Host '  Turn a folder or a selection of tracks into a Winamp playlist' -ForegroundColor DarkGray
    Write-Host '  ---------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
}
function Write-Step { param([string]$T) Write-Host "  $T" -ForegroundColor Cyan }
function Write-Ok   { param([string]$T) Write-Host "  $T" -ForegroundColor Green }
function Write-Note { param([string]$T) Write-Host "  $T" -ForegroundColor DarkGray }
function Write-Bad  { param([string]$T) Write-Host "  $T" -ForegroundColor Red }

# ------------------------------------------------------------- get source ----

function Get-LocalRoot {
    # $PSScriptRoot is empty when this script is piped into iex.
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here) -and $MyInvocation.MyCommand.Path) {
        $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not [string]::IsNullOrWhiteSpace($here) -and
        (Test-Path -LiteralPath (Join-Path $here 'src\winamp-playlist.ps1'))) {
        return $here
    }
    return $null
}

function Test-SamePath {
    param([string] $A, [string] $B)
    if (-not $A -or -not $B) { return $false }
    $norm = { param($p) $p.TrimEnd('\', '/').ToLowerInvariant() }
    return ((& $norm $A) -eq (& $norm $B))
}

function Clear-InstallDir {
    param([string] $Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
        return
    }
    Get-ChildItem -LiteralPath $Destination -Force |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
}

function Copy-RepoInto {
    param([string] $Source, [string] $Destination)

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    Clear-InstallDir -Destination $Destination

    Get-ChildItem -LiteralPath $Source -Force |
        Where-Object { $_.Name -notin @('.git', '.github') } |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
        }

    Write-Ok "Installed to $Destination"
    return $Destination
}

function Get-RepoFromWeb {
    param([string] $Destination)

    Write-Step "Downloading $RepoOwner/$RepoName..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $zipUrl  = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$RepoRef.zip"
    $tmp     = Join-Path ([System.IO.Path]::GetTempPath()) ('winampplaylist_' + [Guid]::NewGuid().ToString('N'))
    $zipPath = "$tmp.zip"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'winamp-playlist-maker-installer')
        $wc.DownloadFile($zipUrl, $zipPath)

        [System.IO.Directory]::CreateDirectory($tmp) | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force

        # The zip contains a single "<repo>-<ref>" folder.
        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if (-not $inner) { throw 'Downloaded archive looked empty.' }

        return (Copy-RepoInto -Source $inner.FullName -Destination $Destination)
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------- main ----

Write-Head

try {
    $local = Get-LocalRoot
    if ($local) {
        if ($InPlace -or (Test-SamePath $local $InstallDir)) {
            Write-Ok "Using the copy in $local"
            $root = $local
        } else {
            Write-Step "Copying to $InstallDir..."
            $root = Copy-RepoInto -Source $local -Destination $InstallDir
        }
    } else {
        $root = Get-RepoFromWeb -Destination $InstallDir
    }

    Write-Step 'Registering the right-click menu...'
    $register = Join-Path $root 'src\install-context-menu.ps1'
    if (-not (Test-Path -LiteralPath $register)) { throw "Missing $register" }
    & $register -ScriptPath (Join-Path $root 'src\winamp-playlist.ps1') | Out-Null

    Write-Host ''
    Write-Ok 'Done.'
    Write-Host ''
    Write-Note 'Right-click a folder of music, or select some audio files:'
    Write-Note '  Show more options  >  Create Winamp Playlist / Add to Winamp Playlist'
    Write-Note '(Shift+F10 opens that menu directly on Windows 11.)'
    Write-Host ''
    Write-Note 'To remove it later, run Uninstall.cmd in:'
    Write-Note "  $root"
    Write-Host ''
}
catch {
    Write-Host ''
    Write-Bad "Install failed: $($_.Exception.Message)"
    Write-Host ''
    exit 1
}
