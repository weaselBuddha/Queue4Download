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
# (bad credentials, missing binary). A one-shot BrokerLinkCheck gates
# the loop: when the broker cannot be reached at startup the daemon
# exits 1 and the service (or the cron keepalive) restarts it.
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
    local -a _auth
    local _rc

    # Best effort in bus mode: published before the subscription below
    # attaches, so this line may not appear in the central file.
    log INFO "central log daemon started"

    # One-shot verification that comms with the broker are established
    # before the loop (no heartbeat: once the broker is reachable, the
    # subscriber reconnects on its own). When the check fails, exit 1 -
    # the unit's Restart=on-failure (or the cron keepalive) retries
    # while the broker comes up.
    if ! BrokerLinkCheck 3
    then
        log FAIL "broker link not established (${BUS_HOST}:${BUS_PORT}) - check the broker and the client cert config (${XDG_CONFIG_HOME:-${HOME}/.config}/mosquitto_pub); exiting for a restart"
        return 1
    fi
    log INFO "broker link established (${BUS_HOST}:${BUS_PORT})"

    while true
    do
        bus_auth _auth sub
        "${SUBSCRIBER}" -h "${BUS_HOST}" -p "${BUS_PORT}" -t "${LOG_CHANNEL}" "${_auth[@]}" >> "${CENTRAL_LOG}" 2>&1
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
