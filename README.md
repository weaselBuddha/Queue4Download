# Queue4Download

Set of Scripts to automate push notification of completed torrent payloads for integration into home plex library

## Scripts

There are a total of four scripts, two on the server (most likely seedbox), and two on the plex box (at home?)

### Server

Queue4Download.sh - RTorrent Hook Script. Throws an event upon completion of the torrent, uses the payload name, the payload hash, and a simple category code

EventAck.sh - Daemon script to listen for ACK events and change the torrent label

### Client

EventProcess.sh - Received Event Dispatch Daemon Script. Catches an event, queues an LFTP job to transfer the payload

LFTPtransfer.sh - Transfer Engine. Using LFTP get the payload from the server to a specific directory (using the category code) on the client, and acknowledge the transfer back to the server.

## Prerequisites

Uses Mosquitto MQTT simple event broker: mosquitto daemon is the broker, mosquitto_pub publishes an event, mosquitto_sub catches an event (publish and subscribe)

Uses pyrocore command suite, specifically rtcontrol, to retrieve details about the torrent like the Hash, and to set the label to indicated Queued and Transferred.

Uses LFTP for quick transfers

## Notes

Scripts have been structured to make customization straight forward, adding in categories, changing torrent client, destination paths, or even the broker should be easy for anyone familiar with Bash scripting.

Uses some of Bash 4.4, been tested on Ubuntu and FreeBSD. This has NOT been tested for any form of Windows or Windows emulation, or OSX. Mosquitto runs on all of them, it is Bash Daemon handling that would be an issue.

Further notes: https://www.reddit.com/r/Chmuranet/comments/f3lghf/queue4download_scripts_to_handle_torrent_complete/
https://www.reddit.com/r/sbtech/comments/nih988/queue4download_scripts_to_handle_torrent_complete/
