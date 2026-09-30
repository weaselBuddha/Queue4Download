#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Dlib.sh - Shared functions (installed on BOTH server and client)
#
# Requires Q4Dconfig.sh and Q4Ddefines.sh to be sourced first.
# The flat file log() writes to is LOG_FILE, picked once below from
# Q4D_ROLE - scripts no longer set a log path themselves.
#
# Interface rules:
#   log <LEVEL> <msg...>       writes one line to the active log sink,
#                              chosen by LOG_MODE (either/or, never both):
#                              flat -> this machine's flat file (LOG_FILE),
#                              bus -> "Logs" channel
#   log_pub <SEV> <msg>        the bus sink for log(): one "Logs" channel
#                              event (central flat file, written by LogD.sh)
#   PublishEvent <ch> <event>  returns the publisher's exit status, prints nothing
#   GetEvent <channel>         prints one payload, returns the subscriber's status
#   WaitLock <lockfile>        blocks until free, then holds it
#   make_label_event <h> <l>   prints a "Label" payload
#   labelling_enabled          true when LABELLING is "true"

## LOG_FILE - this machine's flat log file (flat mode: log()'s sink;
## bus mode: the daemons' stray-output safety net). One per machine,
## chosen by Q4D_ROLE (Q4Dconfig.sh).
if [[ "${Q4D_ROLE}" == "client" ]]
then
    readonly LOG_FILE="${CLIENT_LOG}"
else
    readonly LOG_FILE="${SERVER_LOG}"
fi

## log <LEVEL> <message...>
## Single entry point, one sink, chosen by LOG_MODE (either/or, never both):
##   flat -> appends "<timestamp> [LEVEL] message" to this machine's flat
##           file (LOG_FILE)
##   bus  -> one event on the "Logs" channel (LogD.sh writes it to the
##           central flat file)
## Anything other than "bus" is treated as flat (it needs no broker).
## The timestamp is a bash builtin (printf %()T): no fork per line.
function log()
{
    local _level=$1
    local _ts
    shift

    if [[ "${LOG_MODE}" == "bus" ]]
    then
        log_pub "$@"
    else
        printf -v _ts '%(%Y-%m-%d %H:%M:%S)T' -1
        printf '%s [%s] %s\n' "${_ts}" "${_level}" "$*" >> "${LOG_FILE}"
    fi
}

## log_pub <SEVERITY> <message>
## The bus-side sink for log(): publishes one line to the "Logs" channel,
## where LogD.sh writes it to the central flat file. Format:
## <timestamp> | <SEVERITY> | <message>. Returns the publisher's exit
## status. The message must be one line (publish line by line for captures).
function log_pub()
{
    local _ts

    printf -v _ts '%(%Y-%m-%d %H:%M:%S)T' -1
    "${PUBLISHER}" -h "${BUS_HOST}" -p "${BUS_PORT}" -t "${LOG_CHANNEL}" -u "${BUS_USER}" -P "${BUS_PW}" \
        -m "${_ts} | $1 | $2" -q 1
}

## PublishEvent <channel> <event>
## Publishes one message at QoS 1 (subscribers are fresh connections with
## no persistent session, so higher QoS buys nothing - see Q4Ddefines.sh).
## Returns the publisher's exit status (0 = ok); prints nothing, so both
## styles work:
##     PublishEvent ...; rc=$?
##     if PublishEvent ...; then
function PublishEvent()
{
    "${PUBLISHER}" -h "${BUS_HOST}" -p "${BUS_PORT}" -t "$1" -u "${BUS_USER}" -P "${BUS_PW}" -m "$2" -q 1
}

## GetEvent <channel>
## Blocks until one message arrives on <channel>. Prints the raw payload
## (tab-separated fields) and returns the subscriber's exit status.
## The caller splits it, e.g.:
##     IFS=$'\t' read -r -a _fields <<< "$_payload"
function GetEvent()
{
    "${SUBSCRIBER}" -h "${BUS_HOST}" -p "${BUS_PORT}" -t "$1" -u "${BUS_USER}" -P "${BUS_PW}" -C 1
}

## WaitLock <lockfile>
## Blocks until <lockfile> is free, then holds it for the life of the
## process. Pass a distinct lockfile per lock:
##     server hook:     WaitLock "$Q4D_PATH/.hook.lock"
##     client transfer: WaitLock "$Q4D_PATH/.transfer.lock"
function WaitLock()
{
    exec 5>"$1"
    flock 5
}

## make_label_event <hash> <label>
## Builds a "Label" channel payload.
function make_label_event()
{
    printf "%s\t%s\n" "$1" "$2"
}

## labelling_enabled
## Single source of truth for the LABELLING switch. (v1's
## "[[ $LABELLING && ... ]]" was always true, because "false" is non-empty.)
function labelling_enabled()
{
    [[ "${LABELLING}" == "true" ]]
}
