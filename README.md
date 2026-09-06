# winamp-playlist-maker

Right-click a folder of music (or select some audio files) in Windows Explorer
and turn them into a Winamp/WACUP playlist — no dragging into the player, no
manually building an M3U by hand.

```
Right-click a folder   ->  Create Winamp Playlist
Right-click some files ->  Add to Winamp Playlist
```

Either way, an `.m3u8` gets built (naturally sorted, so "Track 2" comes before
"Track 10") and handed straight to WACUP or Winamp.

## Install

Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/mickeyperry/winamp-playlist-maker/main/install.ps1 | iex
```

Or download / clone the repo and double-click **`Install.cmd`**.

Either way the files end up in `%LOCALAPPDATA%\Programs\winamp-playlist-maker`
and the menu points there, so it keeps working after you delete the download.
It's a per-user install — no admin rights, nothing written outside `HKCU` and
your own profile.

## Use

Right-click a folder full of tracks, or select one or more audio files
(`.mp3`, `.flac`, `.wav`, `.m4a`, `.ogg`, `.wma`, `.aac`, `.opus`). On Windows
11 the entry sits under **Show more options** (or press `Shift+F10` to open
that menu directly).

- **Create Winamp Playlist** (folders) — recurses into the folder, naturally
  sorts what it finds, and saves `<FolderName>.m3u8` *inside* that folder with
  paths relative to it — so the playlist still works if you move the whole
  folder somewhere else.
- **Add to Winamp Playlist** (files) — works on multiple selected files at
  once, and saves to `Documents\Winamp Playlists\Playlist_<timestamp>.m3u8`.

Either way, the playlist is then handed to WACUP or Winamp automatically
(whichever is installed) — it opens with everything queued up, ready to play.

## How it works

| File | Role |
|---|---|
| `install.ps1` | Dual-mode installer — web one-liner or local clone. |
| `src\launch-hidden.vbs` | Verb entry point: starts the worker with zero console flash (`wscript.exe` has no console, and it launches the child hidden from creation). |
| `src\winamp-playlist.ps1` | The worker: collects audio files, naturally sorts them, writes the M3U8, launches the player — with a small progress dialog while it works. |
| `src\install-context-menu.ps1` | Writes the right-click entries into `HKCU`, one per audio extension plus one for folders. |
| `src\uninstall-context-menu.ps1` | Removes them. |

Multiple selected files or folders are combined into a single playlist.
Explorer is told `MultiSelectModel=Player` for these verbs, but Explorer does
not honor that reliably for per-extension verbs — with N files selected it may
launch the command N times, once per file. The worker defends against that
twice over: a named mutex plus a recent-run marker collapse the burst so only
the first process does any work, and that process reads the real, complete
selection straight from the Explorer window via Shell COM — so it sees all N
files even when its own command line carried only one.

The player itself is found by checking the usual `WACUP`/`Winamp` install
locations under Program Files, falling back to the `App Paths` registry
entries Windows installers register. If neither is found, the playlist is
still written to disk and you're told where.

## Uninstall

Double-click **`Uninstall.cmd`** in `%LOCALAPPDATA%\Programs\winamp-playlist-maker`,
or run:

```powershell
powershell -ExecutionPolicy Bypass -File .\src\uninstall-context-menu.ps1
```

That removes the `WinampPlaylistMaker` verb under each registered extension
and `Directory`, nothing else. The script files stay on disk; delete the
install folder yourself if you want them gone too.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (ships with Windows)
- [WACUP](https://getwacup.com/) or classic Winamp, for the playlist to open
  into (the playlist file itself is written either way)

## License

MIT
