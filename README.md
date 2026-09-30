# Queue4Download

Set of Scripts written by Chmura to automate push notification of completed torrent payloads for integration into a home media library while updating the torrent client on a remote server.


# Why Q4D?

Seedboxes have limited storage, if you want to retain your payloads in a media library application like Plex, Jellyfin, Kodi or Emby you need to copy from your seedbox to home. This is currently not well integrated with torrent clients, and requires automation that 'sync's' your media libraries, packages like rsync, syncthing or resilio - which poll your seedbox (say every hour or half hour), and copy anything new home - relying on directory structure and naming to organize your media.

Queue4Download addresses all of these issues - the scripts integrate directly with your torrent client, and can use labelling to capture progress. By using a lightweight message bus like Mosquitto, the process becomes a push not a pull, no more polling. The torrent finishes, the event is queued and captured by your home server, which spawns an LFTP job from home to transfer (very fast) from where the torrent lives to where you specify in your media library. Destinations are mapped by you, based on such criteria as tracker, title, path or label. Queue4Download is written to handle torrents, unlike generic utilities. This means that usually it is minutes, not hours, that your media appears in your media server. All automated.


# Versions

- `Q4Dv2/` - current. Same architecture (MQTT event bus + LFTP transfer), reorganized by deployment role, with the v1 bug fixes applied. Full layout, the v1 -> v2 change list, logging and install details are in `Q4Dv2/README.md`.
- `Q4D/` - the original (v1) flat layout, kept untouched for existing installs. The v2 installed layout (`~/.Q4D/`) is the same shape, so v1 users can adopt v2 file-for-file.


## Quick start (v2)

    # seedbox
    git clone https://github.com/weaselBuddha/Queue4Download
    ~/Queue4Download/Q4Dv2/install.sh server --client=rtcontrol

    # home server
    ssh you@seedbox 'cat ~/Queue4Download/Q4Dv2/install.sh' | bash -s client you@seedbox

`install.sh server` lays out `common/` + `server/` flat into `~/.Q4D/` on the seedbox and selects the torrent client tool. `install.sh client` pulls the shared config and client files over SFTP, verifies the broker, builds the TypeCodes map from the server's Types.config, and installs the systemd units (processEvent, logDaemon).

In pipe mode the prompts read the pipe's stdin, so every question takes its default; to answer them interactively, copy install.sh over and run it from disk.


## Scripts (v2)

Role split, installed flat into `~/.Q4D/` (the same shape v1 users already have):

- common (BOTH machines) - Q4Dconfig.sh (bus co-ords, credentials, LABELLING, log mode + per-machine log files), Q4Ddefines.sh (channels, labels, event protocol), Q4Dlib.sh (PublishEvent, GetEvent, log, WaitLock), LogD.sh (central log daemon, bus mode)
- server (SEEDBOX) - Queue4Download.sh (torrent completion hook), LabelD.sh (label daemon), Types.config (type code rules), torrent tools (one plugin per torrent client, installed as TorrentTool.sh), labellers/
- client (HOME) - ProcessEvent.sh (queue daemon), LFTPtransfer.sh (transfer engine + ACK/NACK), Q4Dclient.sh (LFTP settings + TypeCodes map), systemd units


## Prerequisites

The ability to make simple edits to shell scripts, a seedbox/server that has bash/ssh access.

Scripts use Bash 4.0+ features. Tested on Ubuntu and FreeBSD. This has NOT been tested for any form of Windows or Windows emulation, or OSX. Mosquitto runs on all of them, it is the Bash daemon handling that would be an issue.

Uses Mosquitto MQTT simple event broker: the mosquitto daemon is the broker, mosquitto_pub publishes an event, mosquitto_sub catches an event (publish and subscribe). v2 prefers the distro binaries on the PATH (falling back to /usr/bin) - the v1 prebuilt mosq_bin tarball is no longer shipped.

Labelling, not part of the torrent standard, is accomplished by specific client extensions, such as rtcontrol from pyroscope, and deluge-console from deluge.

Uses LFTP for quick transfers (throttle set in Q4Dclient.sh).

Python3 for the labellers: delugeLabeller.py (pip install deluge-client), qbitLabeller.py (pip install qbittorrent-api). rTorrent: pyrosimple https://github.com/kannibalox/pyrosimple


## Docker

Community-owned packaging (the doc "Dockerized Q4D Client.md" was removed from the repo root - see git history). The container simply lays out `common/` + `client/` into `$HOME/.Q4D/` and runs ProcessEvent.sh; the seedbox side stays plain scripts.


## Notes

Scripts have been structured to make customization straightforward, adding in categories, changing torrent client, destination paths, or even the broker should be easy for anyone familiar with Bash scripting.

Install instructions:

https://www.reddit.com/r/sbtech/comments/1ams0hn/q4d_updated/

Older: https://www.reddit.com/r/Chmuranet/comments/f3lghf/queue4download_scripts_to_handle_torrent_complete/
https://www.reddit.com/r/sbtech/comments/nih988/queue4download_scripts_to_handle_torrent_complete/
