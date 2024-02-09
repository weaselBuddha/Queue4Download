# Queue4Download

Set of Scripts to automate push notification of completed torrent payloads for integration into home plex library

## Scripts

There are a total of four scripts, and four config files, two on the server (most likely seedbox) and Q4Dconfig.sh (both client and server configuration must be changed to work) 



### Server

Queue4Download.sh - RTorrent Hook Script. Throws an event upon completion of the torrent, uses the payload name, the payload hash, and a simple category code

LabelD.sh - Daemon script to listen for Label events and change the torrent label

Types.config - Flat file declarations for type code assignment

Q4Dconfig.sh - MQTT co-ords, torrent client, and labelling definitions (needed on both client and server)

### Client

ProcessEvent.sh - Received Event Dispatch Daemon Script. Catches an event, queues an LFTP job to transfer the payload, runs as a daemon

LFTPtransfer.sh - Transfer Engine. Using LFTP get the payload from the server to a specific directory (using the category code) on the client, and acknowledge the transfer back to the server.

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
