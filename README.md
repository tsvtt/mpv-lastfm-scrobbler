# Mpv player plugin for scrobbling music to [last.fm](https://last.fm)

### Platforms
- Linux
- Possibly other Unixes (**UNTESTED**)

### Installation
- Verify `curl` is installed and found on `$PATH`. Install it with `apt install curl` or any other package manager
- Download and drop the plugin file [lastfm_scr.lua](lastfm_scr.lua) into the mpv script directory. With default mpv installation it is `~/.config/mpv/scripts/`. Create directory `scripts` if it doesn't exist
- Launch `mpv` and confirm the last.fm API session using your browser (a new browser page should open automatically)
- Play an audio file

### Info
- By default, only `mp3/flac/m4a` formats are recognized. Edit the format list in the script file and add additional formats if needed.

### Troubleshooting
- Launch `mpv` in the CLI-mode from a terminal and look for any errors; if no errors visible, launch mpv with debug parameter: `--msg-level=lastfm_scr=debug`
