# Queue4Download

Set of Scripts written by Chmura to automate push notification of completed torrent payloads for integration into a home media library.


# Why Q4D?

Seedboxes have limited storage, if you want to retain your payloads in a media library application like Plex, Jellyfin, Kodi or Emby you need to copy from your seedbox to home. This is currently not well integrated into torrent clients, and requires automation that 'syncs' your media libraries, packages like rsync, syncthing or resilio - all of which poll your seedbox (say every hour or half hour), and copy anything new home - relying on directory structure and linking to organize your media.

Queue4Download addresses all of these issues - the scripts integrate directly with the torrent client, and can use labelling to capture progress. By using a lightweight message bus like Mosquitto, the process becomes a push not a pull, no more polling. The torrent finishes, the event is queued and captured by your home server, which spawns an LFTP job from home to transfer (very fast) from where the torrent lives to where you specify in your media library. Destinations are mapped by you, based on such criteria as tracker, title, path or label. Queue4Download is written to handle torrents, unlike generic utilities. This means that usually it is minutes, not hours that your media appears in your media server. All automated.


## Scripts

There are a total of four scripts, and four config files, two on the server (most likely seedbox) and Q4Dconfig.sh (both client and server configuration must be changed to work) 


### Server

Queue4Download.sh - Torrent client hook Script. Throws an event upon completion of the torrent, uses the payload name, the payload hash, and a simple category code

LabelD.sh - Daemon script to listen for Label events and change the torrent label

Types.config - Flat file declarations for type code assignment

Q4Dconfig.sh - MQTT co-ords, torrent client, and labelling definitions (needed on both client and server)


### Client

ProcessEvent.sh - Receive Queue Event Script. Catches the event, queues an LFTP job to transfer the payload, runs as a daemon. Blocks waiting for a Queue event.

LFTPtransfer.sh - Transfer Engine. Using LFTP get the payload from the server to a specific directory (using the category code) into your home library, and acknowledge the transfer back to the server.

Q4Dclient.sh - Definitions for LFTP to access your server, and type code to directory mappings


## Prerequisites

The ability to make simple edits to shell scripts, a seedbox/server that has bash/ssh access. 

Server scripts use Bash 4.0 features. Client is compatible with BSD, Linux, and other Unix variants.

Uses Mosquitto MQTT simple event broker: mosquitto daemon is the broker, mosquitto_pub publishes an event, mosquitto_sub catches an event (publish and subscribe)

Labelling, not part of the torrent standard, is accomplished by specific client extensions, such as rtcontrol from pyroscope, and deluge-console from deluge.

Uses LFTP for quick transfers


## Notes

Scripts have been structured to make customization straight forward, adding in categories, changing torrent client, destination paths, or even the broker should be easy for anyone familiar with Bash scripting.

Uses some of Bash 4.4, been tested on Ubuntu and FreeBSD. This has NOT been tested for any form of Windows or Windows emulation, or OSX. Mosquitto runs on all of them, it is Bash Daemon handling that would be an issue.

Further notes, install instructions:

https://www.reddit.com/r/sbtech/comments/1ams0hn/q4d_updated/


Older: https://www.reddit.com/r/Chmuranet/comments/f3lghf/queue4download_scripts_to_handle_torrent_complete/
https://www.reddit.com/r/sbtech/comments/nih988/queue4download_scripts_to_handle_torrent_complete/
