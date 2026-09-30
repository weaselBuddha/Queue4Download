#!/bin/bash
# vi: ts=4:sw=4:et
#
# LogD.sh - Central log daemon (CLIENT, SERVER, or BOTH; bus mode)
#
# Subscribes to the "Logs" channel and appends every message to
# ~/.Q4D/q4d_central.log. In bus mode (LOG_MODE=bus in Q4Dconfig.sh),
# every Q4D script's log() lines (hook, daemons, transfer engine) land
# here, so one file holds the whole system's history. Run it on the home
# server, on the seedbox, or on both (one flat file per machine). In flat
# mode nothing is published, so this daemon is not needed.
#
# mosquitto_sub reconnects on its own; the loop only restarts hard exits
# (bad credentials, missing binary).
#
# shellcheck disable=SC1090,SC1091  # source paths resolve only at runtime

source ~/.Q4D/Q4Dconfig.sh
source "$Q4D_PATH/Q4Ddefines.sh"
source "$Q4D_PATH/Q4Dlib.sh"

readonly CENTRAL_LOG="$Q4D_PATH/Q4Dcentral.log"

## Main
## Subscribes forever.
function Main()
{
    local _rc

    # Best effort in bus mode: published before the subscription below
    # attaches, so this line may not appear in the central file.
    log INFO "central log daemon started"

    while true
    do
        "${SUBSCRIBER}" -h "${BUS_HOST}" -p "${BUS_PORT}" -t "${LOG_CHANNEL}" -u "${BUS_USER}" -P "${BUS_PW}" >> "${CENTRAL_LOG}" 2>&1
        _rc=$?

        if [[ ${_rc} -eq 0 ]]
        then
            break
        fi

        log WARN "central log subscriber exited (rc ${_rc}) - retry in 5s"
        sleep 5
    done
}

Main
