#!/bin/bash
# vi: ts=4:sw=4:et
#
# Queue4Download.sh - Torrent client completion hook (SERVER side)
#
# Invoked by the torrent client on completion (each TorrentTool.* header
# shows the exact hook line).
#
#   tool GetPayloadDetails -> CheckFields -> SetType (Types.config)
#   -> publish "Down" -> optional "Label" (QUEUED / NOT_QD) -> one log line
#
# The hook's one piece of shared state is the payload record below. It is
# private (_payload) and is only touched through payload_set / payload_get,
# which validate the field name - so a typo in a tool or in Types.config
# can no longer silently create a new key.
#
# shellcheck disable=SC1090,SC1091  # source paths resolve only at runtime
# shellcheck disable=SC2034         # _payload is consumed by the payload_* functions

source ~/.Q4D/Q4Dconfig.sh
source "$Q4D_PATH/Q4Ddefines.sh"
source "$Q4D_PATH/Q4Dlib.sh"
source "$Q4D_PATH/Q4Dserver.sh"

## --- the payload record ------------------------------------------------------
## The tool fills KEY, HASH, LABEL, TRACKER, PATH (via payload_set).
## This hook adds TYPE.
declare -A _payload=()

## _payload_field <NAME>
## True if NAME is a field of the record.
function _payload_field()
{
    case $1 in
        KEY|HASH|LABEL|TRACKER|PATH|TYPE) return 0 ;;
        *) return 1 ;;
    esac
}

## payload_set <FIELD> <value>
## The only door into the record.
function payload_set()
{
    local _rc=0

    if _payload_field "$1"
    then
        _payload[$1]="${2-}"
    else
        log FAIL "unknown payload field: $1"
        _rc=1
    fi

    return ${_rc}
}

## payload_get <FIELD>
## The only door out of the record. Prints the value.
function payload_get()
{
    local _rc=0

    if ! _payload_field "$1"
    then
        log FAIL "unknown payload field: $1"
        _rc=1
    fi

    printf '%s\n' "${_payload[$1]-}"

    return ${_rc}
}

## --- torrent tool --------------------------------------------------------------

## check_tool
## Finds, sources and validates the selected torrent tool.
function check_tool()
{
    local _rc=1

    if [[ -f "$Q4D_PATH/TorrentTool.sh" ]] && source "$Q4D_PATH/TorrentTool.sh"
    then
        if declare -F GetPayloadDetails >/dev/null
        then
            _rc=0
        else
            log FAIL "TorrentTool.sh does not define GetPayloadDetails"
        fi
    else
        log FAIL "TorrentTool.sh missing - run 'install.sh server' (or copy torrenttools/TorrentTool.<client> to TorrentTool.sh)"
    fi

    return ${_rc}
}

## --- validation and typing -----------------------------------------------------

## CheckFields <num-args>
## A valid record has a PATH that exists (it then becomes the KEY), or a
## KEY that exists. A hook with no args (e.g. transmission) must still have
## produced a KEY. Leaves HASH as "NotUsed" when the tool had no hash.
function CheckFields()
{
    local _numargs=$1
    local _key
    local _path
    local _rc=0

    _key=$(payload_get KEY)
    _path=$(payload_get PATH)

    if [[ ${_numargs} -gt 0 || -n "${_key}" ]]
    then
        if [[ -n "${_path}" && -e "${_path}" ]]
        then
            payload_set KEY "${_path}"
        elif [[ -e "${_key}" ]]
        then
            if [[ -z "$(payload_get HASH)" ]]
            then
                payload_set HASH "NotUsed"
            fi
        else
            log FAIL "no usable payload: neither PATH (${_path}) nor KEY (${_key}) exists"
            _rc=1
        fi
    else
        log FAIL "no usable payload: hook passed no args and produced no KEY"
        _rc=1
    fi

    return ${_rc}
}

## rule_matches <field> <comparator> <value>
## True when the record's <field> passes a Types.config comparison:
## IS (exact), CONTAINS (substring), NOT (exact mismatch).
function rule_matches()
{
    local _data
    local _match=1

    _data=$(payload_get "$1")

    case $2 in
        "IS")       [[ "${_data}" == "$3" ]]   && _match=0 ;;
        "CONTAINS") [[ "${_data}" == *"$3"* ]] && _match=0 ;;
        "NOT")      [[ "${_data}" != "$3" ]]   && _match=0 ;;
        *)          log WARN "Types.config: unknown comparator '$2'" ;;
    esac

    return ${_match}
}

## SetType
## Applies Types.config (tier 1 first, tier 2 after) to the record and
## stores the result as TYPE. Falls back to DEFAULT_TYPE.
function SetType()
{
    local _type=""
    local _field _comparator _value _code _assigned

    # Process substitution: no temp file for a handful of rules.
    while read -r _field _comparator _value _code _assigned
    do
        if [[ "${_type}" == "${_assigned}" ]] && rule_matches "${_field}" "${_comparator}" "${_value}"
        then
            _type=${_code}
        fi
    done < <(grep -Ev '(#.*$)|(^$)' "$TYPE_CODES")

    if [[ -z "${_type}" ]]
    then
        _type=${DEFAULT_TYPE}
    fi

    payload_set TYPE "${_type}"
}

## --- publishing ------------------------------------------------------------------

## CreateQEvent
## Builds the "Down" payload: PATH <TAB> HASH <TAB> TYPE
## (a tab in the path would break the field count; the client rejects
## malformed events with a WARN)
function CreateQEvent()
{
    printf "%s\t%s\t%s\n" "$(payload_get PATH)" "$(payload_get HASH)" "$(payload_get TYPE)"
}

## MarkQueued <publish-rc>
## Publishes QUEUED (rc 0) or NOT_QD, when the record has a real hash.
function MarkQueued()
{
    local _hash
    local _label

    _hash=$(payload_get HASH)

    if [[ "${_hash}" != "NotUsed" ]]
    then
        if [[ $1 == 0 ]]
        then
            _label=${Q_LABEL}
        else
            _label=${Q_FAIL}
        fi
        PublishEvent "${LABEL_CHANNEL}" "$(make_label_event "${_hash}" "${_label}")"
    fi
}

## LogEvent <publish-rc> <start-seconds>
## The one summary line for this run (active log sink).
function LogEvent()
{
    local _result
    local _elapsed=$(( SECONDS - $2 ))
    local _summary

    if [[ $1 == 0 ]]
    then
        _result="SUCCESS"
    else
        _result="FAIL"
    fi

    _summary="<$(payload_get KEY)> $(payload_get HASH) [$(payload_get TYPE)] ${_elapsed}s"

    log "${_result}" "${_summary}"
}

## --- entry point -------------------------------------------------------------------

## Main <hook-args...>
## Runs the whole hook once.
function Main()
{
    local _event
    local _queued=1
    local _start=${SECONDS}

    log INFO "hook started (client=${TORRENT_CLIENT}, args=$#)"

    WaitLock "${Q4D_PATH}/.hook.lock"

    GetPayloadDetails "$@"

    if CheckFields "$#"
    then
        SetType
        _event=$(CreateQEvent)
        PublishEvent "${QUEUE_CHANNEL}" "${_event}"
        _queued=$?
    fi

    if labelling_enabled
    then
        MarkQueued "${_queued}"
    fi

    LogEvent "${_queued}" "${_start}"
}

check_tool || exit 1

Main "$@"
