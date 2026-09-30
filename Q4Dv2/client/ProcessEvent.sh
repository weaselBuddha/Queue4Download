#!/bin/bash
# vi: ts=4:sw=4:et
#
# ProcessEvent.sh - Queue daemon (CLIENT side)
#
# Subscribes to the "Down" channel and forks one LFTPtransfer.sh per event
# (the transfers serialize themselves on the transfer lock).
# One failed subscribe retries after 5s instead of killing the daemon.
#
# shellcheck disable=SC1090,SC1091  # source paths resolve only at runtime
# shellcheck disable=SC2154         # TypeCodes comes from sourced Q4Dclient.sh

source ~/.Q4D/Q4Dconfig.sh
source "$Q4D_PATH/Q4Ddefines.sh"
source "$Q4D_PATH/Q4Dlib.sh"
source "$Q4D_PATH/Q4Dclient.sh"

# Stray stdout/stderr safety net: always lands in the local flat file, even
# in bus mode (unstructured output has no other home).
exec >> "$LOG_FILE" 2>&1

## --- pre-flight checks -----------------------------------------------------------
## Each check logs its own failure and returns 1; verify_environment runs
## them all before the subscribe loop. Failures are non-fatal: the loop
## retries, so a downed broker or seedbox heals itself.

## check_binaries
## True when every binary the scripts actually invoke is present:
## ${PUBLISHER} and ${SUBSCRIBER} by their configured paths, lftp on PATH.
function check_binaries()
{
    local _missing=""

    if [[ ! -x "${PUBLISHER}" ]]
    then
        _missing="${_missing} ${PUBLISHER}"
    fi

    if [[ ! -x "${SUBSCRIBER}" ]]
    then
        _missing="${_missing} ${SUBSCRIBER}"
    fi

    if ! command -v lftp >/dev/null
    then
        _missing="${_missing} lftp"
    fi

    if [[ -n "${_missing}" ]]
    then
        log ERROR "missing binaries:${_missing}"
    fi

    [[ -z "${_missing}" ]]
}

## check_broker
## True when a probe publish reaches the broker.
function check_broker()
{
    local _rc=1

    if "${PUBLISHER}" -h "${BUS_HOST}" -p "${BUS_PORT}" -u "${BUS_USER}" -P "${BUS_PW}" -t "Q4D/check" -m ok -q 1
    then
        _rc=0
    fi

    if [[ ${_rc} -ne 0 ]]
    then
        log ERROR "broker not reachable at ${BUS_HOST}:${BUS_PORT}"
    fi

    return ${_rc}
}

## check_server
## True when the seedbox answers on its SFTP port (TCP probe).
function check_server()
{
    local _rc=1

    if (exec 3<>"/dev/tcp/${HOST}/22") 2>/dev/null
    then
        _rc=0
    fi

    if [[ ${_rc} -ne 0 ]]
    then
        log ERROR "seedbox ${HOST} not reachable on port 22"
    fi

    return ${_rc}
}

## check_typecodes
## True when every TypeCodes destination exists (creates missing ones).
function check_typecodes()
{
    local _bad=""
    local _code
    local _dir

    for _code in "${!TypeCodes[@]}"
    do
        _dir=${TypeCodes[${_code}]}
        if ! mkdir -p "${_dir}" 2>/dev/null
        then
            _bad="${_bad} ${_code}:${_dir}"
        fi
    done

    if [[ -n "${_bad}" ]]
    then
        log ERROR "bad destination directories:${_bad}"
    fi

    [[ -z "${_bad}" ]]
}

## verify_environment
## Runs all pre-flight checks; each logs its own failure.
function verify_environment()
{
    local _rc=0

    check_binaries || _rc=1
    check_broker || _rc=1
    check_server || _rc=1
    check_typecodes || _rc=1

    return ${_rc}
}

## dispatch_event <payload>
## Validates one "Down" payload (PATH <TAB> HASH <TAB> TYPE) and forks a
## transfer for it.
function dispatch_event()
{
    local -a _fields=()
    local _payload=$1

    IFS=$'\t' read -r -a _fields <<< "${_payload}"

    if [[ ${#_fields[@]} -eq ${NUM_FIELDS} ]]
    then
        log INFO "event received for ${_fields[${FILENAME}]} (${_fields[${HASH}]}) type ${_fields[${TYPE}]}"
        "$LFTP_SCRIPT" "${_fields[${FILENAME}]}" "${_fields[${HASH}]}" "${_fields[${TYPE}]}" 2>> "$LOG_FILE" &
    else
        log WARN "event malformed (${#_fields[@]} fields, expected ${NUM_FIELDS}) - discarded: ${_fields[*]}"
    fi
}

## Main
## Subscribes forever.
function Main()
{
    local _payload

    log INFO "queue daemon started"

    if ! verify_environment
    then
        log WARN "environment incomplete - continuing, the loop retries"
    fi

    while true
    do
        if _payload=$(GetEvent "${QUEUE_CHANNEL}")
        then
            dispatch_event "${_payload}"
        else
            log WARN "queue subscriber exited (broker down?) - retry in 5s"
            # Re-run the pre-flight so healed problems (broker back, a late
            # mount of a destination) are noticed without a restart.
            verify_environment
            sleep 5
        fi
    done
}

Main
