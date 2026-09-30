#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Dconfig.sh - Shared configuration (installed on BOTH server and client)
#
# Sourced first by every Q4D script. Keep it minimal: event bus, credentials,
# the torrent client marker, the labelling switch, the logging mode, and the
# per-machine log files.
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this

readonly Q4D_PATH=~/.Q4D/

## Event Bus
readonly BUS_HOST="your.mosquitto.ip_addr"
readonly BUS_PORT=1883

# Mosquitto Credentials - Please Change
readonly BUS_USER="mosquitto_user"
readonly BUS_PW="mqtt_password"

# Torrent client in use - set by 'install.sh server' to match TorrentTool.sh
# One of: rtcontrol, rtorrent, deluge, qbit, aria2, other, transmission
readonly TORRENT_CLIENT=CHOOSE

# Do we update the label after Queued?  Regular Success: QUEUED -> DONE  (Failed: NOT_QD / NOPE)
# Requires a labelling tool (the selected TorrentTool's SetLabel). false = no label traffic.
readonly LABELLING=true

# Logging - either/or, not both (system-wide: this file is shared, the client
# installer copies it from the seedbox). Set by 'install.sh server'.
#   flat -> log() appends to this machine's own flat file (SERVER_LOG or
#           CLIENT_LOG, picked by Q4D_ROLE - see below)
#   bus  -> log() publishes one event per message on the "Logs" channel;
#           LogD.sh writes them to the central flat file (run LogD.sh on at
#           least one machine in bus mode)
# Anything other than "bus" is treated as flat (it needs no broker).
readonly LOG_MODE="flat"

## Flat log files - one per machine. In flat mode log() writes to the
## machine's own file; in bus mode the daemons' exec redirects still use it
## as the stray-output safety net. The installer asks for the path when
## flat mode is selected.
readonly SERVER_LOG=$Q4D_PATH/queue.log
readonly CLIENT_LOG=$Q4D_PATH/process.log

## Which side of the link this machine is: server (seedbox) or client
## (home). Written locally by the installer - this shared copy starts as
## server, the client installer flips its own copy to client.
readonly Q4D_ROLE=server
