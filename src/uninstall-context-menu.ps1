#requires -version 5.1
<#
    uninstall-context-menu.ps1
    Removes the Winamp Playlist Maker context menu entries for this user.
    Leaves the script files on disk.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$AudioExtensions = @('.mp3', '.flac', '.wav', '.m4a', '.ogg', '.wma', '.aac', '.opus')
$VerbName = 'WinampPlaylistMaker'

$keys = foreach ($ext in $AudioExtensions) {
    "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\$VerbName"
}
$keys += "HKCU:\Software\Classes\Directory\shell\$VerbName"

Write-Host ''
foreach ($k in $keys) {
    if (Test-Path -LiteralPath $k) {
        Remove-Item -LiteralPath $k -Recurse -Force
        Write-Host "  removed  $k" -ForegroundColor Yellow
    } else {
        Write-Host "  absent   $k" -ForegroundColor DarkGray
    }
}
Write-Host ''
Write-Host '  Context menu removed.' -ForegroundColor Green
Write-Host ''
