#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Ddefines.sh - Shared definitions (installed on BOTH server and client)
#
# Requires Q4Dconfig.sh to be sourced first.
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this

## Publisher/subscriber binaries: prefer what is on the PATH (the
## pre-flight checks these exact paths), fall back to the distro location.
PUBLISHER=$(command -v mosquitto_pub 2>/dev/null || echo /usr/bin/mosquitto_pub)
readonly PUBLISHER
SUBSCRIBER=$(command -v mosquitto_sub 2>/dev/null || echo /usr/bin/mosquitto_sub)
readonly SUBSCRIBER

## Event Channels
readonly QUEUE_CHANNEL="Down"
readonly LABEL_CHANNEL="Label"
readonly LOG_CHANNEL="Logs"

## Label vocabulary
readonly Q_LABEL="QUEUED"
readonly Q_FAIL="NOT_QD"
readonly ACK="DONE"
readonly NACK="NOPE"

## ---------------------------------------------------------------------------
## Event protocol (one line per message, tab-separated)
##
##   "Down" (server -> client) - 3 fields:
##       index 0  FILENAME  payload path on the seedbox (LFTP source)
##       index 1  HASH      torrent info hash (for label updates)
##       index 2  TYPE      type code (Types.config on server, TypeCodes on client)
##
##   "Label" (server + client -> server) - 2 fields:
##       index 0  HASH      torrent info hash
##       index 1  LABEL     QUEUED | NOT_QD | DONE | NOPE
##
##   "Down"  published by:  server Queue4Download.sh
##   "Label" published by:  server Queue4Download.sh (QUEUED / NOT_QD)
##                           client LFTPtransfer.sh   (DONE / NOPE)
##   "Down"  subscribed by: client ProcessEvent.sh
##   "Label" subscribed by: server LabelD.sh
##
##   Delivery: at-most-once. Subscribers are fresh connections (no
##   persistent session), so an event published while its subscriber is in
##   its retry window is lost; there is no requeue.
##
##   "Logs" (any Q4D script -> central log daemon) - free text, one line
##       per message, formatted by log_pub():
##           <timestamp> | <SEVERITY> | <message>
##   "Logs" published by: log(), in bus mode only (LOG_MODE in Q4Dconfig.sh)
##   "Logs" subscribed by: LogD.sh (needed in bus mode, on client and/or server)
## ---------------------------------------------------------------------------

# "Down" event field indexes
readonly FILENAME=0
readonly HASH=1
readonly TYPE=2
readonly NUM_FIELDS=3

# "Label" event field indexes
readonly HASH_INDEX=0
readonly LABEL_INDEX=1
