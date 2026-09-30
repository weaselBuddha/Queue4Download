#!/bin/bash
# vi: ts=4:sw=4:et
#
# LFTPtransfer.sh - Transfer engine (CLIENT side)
#
# Pulls the payload from the seedbox into the destination directory for its
# type code (TypeCodes map), then publishes a "Label" ACK/NACK.
#
#   Main <target> <hash> <type>
#     WaitLock .transfer.lock
#     SetDirectory <type>            cd to the destination (ERR is fallback)
#     TransferPayload <target>       mirror as dir, then pget as file
#     ProcessResult <rc> ...         log, surface failures, publish ACK/NACK
#
# shellcheck disable=SC1090,SC1091  # source paths resolve only at runtime
# shellcheck disable=SC2154         # TypeCodes comes from sourced Q4Dclient.sh

source ~/.Q4D/Q4Dconfig.sh
source "$Q4D_PATH/Q4Ddefines.sh"
source "$Q4D_PATH/Q4Dlib.sh"
source "$Q4D_PATH/Q4Dclient.sh"

## SetDirectory <type>
## Moves to the destination directory for <type>.
function SetDirectory()
{
    local _destination=${TypeCodes[$1]:-${TypeCodes[ERR]}}

    cd "${_destination}" || return 1
}

## run_lftp <lftp-command> <logfile>
## Runs one lftp session against the seedbox; output goes to <logfile>.
function run_lftp()
{
    lftp -u "${CREDS}" "sftp://${HOST}/" -e "$HOSTKEYFIX; $1; quit" >> "$2" 2>&1
}

## TransferPayload <target> <faillog>
## Pulls <target> into the current directory: first as a directory
## (mirror), then as a single file (pget).
function TransferPayload()
{
    local _target=$1
    local _faillog=$2
    local _rc

    umask 0

    log INFO "base: $(basename "${_target}") target: ${_target}"

    run_lftp "mirror -c --parallel=${THREADS} --use-pget-n=${SEGMENTS} \"${_target}\"" "${_faillog}"
    _rc=$?

    if [[ ${_rc} -ne 0 ]]
    then
        run_lftp "pget -n ${THREADS} \"${_target}\"" "${_faillog}"
        _rc=$?
    fi

    # Guard: a failed transfer may have created nothing.
    if [[ -e "$(basename "${_target}")" ]]
    then
        chmod -R 777 "$(basename "${_target}")"
    fi

    return ${_rc}
}

## publish_capture <faillog>
## The exception to the either/or rule, by design: when a transfer fails,
## the captured lftp output is copied to the active log sink - one log()
## per non-blank line.
function publish_capture()
{
    local _file=$1
    local _line

    if [[ -r "${_file}" ]]
    then
        while IFS= read -r _line
        do
            if [[ -n "${_line}" ]]
            then
                log ERROR "${_line}"
            fi
        done < "${_file}"
    fi
}

## ProcessResult <rc> <target> <hash> <faillog>
## Logs the outcome, on failure copies the lftp capture to the active log
## sink (one line per event), publishes the ACK/NACK label, and removes
## the failure log.
function ProcessResult()
{
    local _rc=$1
    local _target=$2
    local _hash=$3
    local _faillog=$4
    local _label
    local _note

    if [[ ${_rc} == 0 ]]
    then
        _label=${ACK}
        _note="transfer of ${_target} completed"
        log INFO "${_note}"
    else
        _label=${NACK}
        _note="transfer of ${_target} failed"
        log ERROR "${_note}"
        publish_capture "${_faillog}"
    fi

    rm -f "${_faillog}"

    if labelling_enabled && [[ "${_hash}" != "NotUsed" ]]
    then
        if PublishEvent "${LABEL_CHANNEL}" "$(make_label_event "${_hash}" "${_label}")"
        then
            _note="label ${_label} published for ${_target}"
            log INFO "${_note}"
        else
            _note="label ${_label} publish FAILED for ${_target}"
            log WARN "${_note}"
        fi
    fi
}

## Main <target> <hash> <type>
function Main()
{
    local _target=$1
    local _hash=$2
    local _type=$3
    local _faillog
    local _note
    local _rc=0

    # Single transfer at a time.
    WaitLock "${Q4D_PATH}/.transfer.lock"

    _faillog=$(mktemp)

    if SetDirectory "${_type}"
    then
        TransferPayload "${_target}" "${_faillog}"
        _rc=$?
    else
        _note="destination bad: ${_type} (target ${_target})"
        log WARN "${_note}"
        _rc=1
    fi

    ProcessResult "${_rc}" "${_target}" "${_hash}" "${_faillog}"

    return ${_rc}
}

Main "$@"
