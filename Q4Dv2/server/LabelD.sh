#!/bin/bash
# vi: ts=4:sw=4:et
#
# LabelD.sh - Label daemon (SEEDBOX)
#
# Subscribes to the "Label" channel and applies each label to the
# torrent client through the installed tool's SetLabel
# (TorrentTool.sh, sourced into this process).
#
# Payloads are "<hash>\t<label>"; label vocabulary is in Q4Ddefines.sh.
#
# The daemon is tolerant: a missing tool, a broker blip or a failed
# SetLabel all log and retry, so a single bad event cannot kill it.
# mosquitto_sub reconnects on its own; the loop only restarts hard
# exits (bad credentials, missing binary).
#
# shellcheck disable=SC1090,SC1091  # source paths resolve only at runtime

source ~/.Q4D/Q4Dconfig.sh
source "$Q4D_PATH/Q4Ddefines.sh"
source "$Q4D_PATH/Q4Dlib.sh"
source "$Q4D_PATH/TorrentTool.sh"

## Check_Tool
## Sources the installed tool (install.sh copied the selected
## TorrentTool.<name> to ~/.Q4D/TorrentTool.sh) and verifies it defines
## the two functions this daemon needs. Returns 0 when ready.
function Check_Tool()
{
    local _rc=1

    # shellcheck source=/dev/null  # the tool is installed at runtime
    source "${Q4D_PATH}/TorrentTool.sh"

    if declare -F GetPayloadDetails >/dev/null && declare -F SetLabel >/dev/null
    then
        _rc=0
    else
        log FAIL "Torrent tool missing or incomplete (need GetPayloadDetails and SetLabel) - see install.sh --client="
    fi

    return ${_rc}
}

## Apply_Label <payload>
## <hash>\t<label> -> the tool's SetLabel.
function Apply_Label()
{
    local _payload=$1
    local _hash
    local _label

    IFS=$'\t' read -r _hash _label <<< "${_payload}"

    if SetLabel "${_hash}" "${_label}"
    then
        log INFO "Label set to ${_label} for ${_hash}"
    else
        log WARN "SetLabel failed (rc $?) for ${_hash} - label ${_label} not applied"
    fi
}

## Main
## Subscribes forever.
function Main()
{
    local _payload

    # We have the tool?
    if [[ $(Check_Tool) -ne 0 ]]
    then
        log FAIL "Label Daemon Bailing"
    else
        log INFO "Label Daemon Started"

        while true
        do
            if _payload=$(GetEvent "${LABEL_CHANNEL}")
            then
                Apply_Label "${_payload}"
            else
                log WARN "Label Subscription Dropped (broker down?) - retry in 5s"
                sleep 5
            fi
        done
    fi
}

## --- entry point ----------------------------------------------------------------


Main
