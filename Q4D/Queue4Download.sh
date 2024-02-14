#!/bin/bash
#vi: ts=4:sw=4:et

source ~/.Q4D/Q4Dconfig.sh
source $Q4D_PATH/Q4Ddefines.sh

numArgs=$#

declare -A payloadDetails

case $TORRENT_CLIENT in

    "RTORRENT")
        payloadDetails[KEY]="$1"
        payloadDetails[HASH]=$2
        payloadDetails[LABEL]=$3
        _rtcFile="$(echo $1|tr  [\]\[\,\'\"] [????])"
        payloadDetails[TRACKER]=$(strings $ACTIVE_TORRENT_FOLDER/$2.torrent |grep "d8:announce" |cut -d: -f4
        payloadDetails[PATH]="$5"
        ;;

    "OTHER")
        payloadDetails[KEY]="$1"
        payloadDetails[HASH]=$2
        payloadDetails[LABEL]=$3
        payloadDetails[TRACKER]=$4
        payloadDetails[PATH]="$5"
        ;;

    "RTCONTROL")
        payloadDetails[KEY]="$1"
        _rtcFile="$(echo "$1"|tr  [\]\[\,\'\"] [????])"
        payloadDetails[HASH]=$(${_RTCONTROL} -q name="${_rtcFile}" -o "hash")
        payloadDetails[LABEL]=$(${_RTCONTROL} -q name="${_rtcFile}" -o "custom_1")
        payloadDetails[TRACKER]=$(${_RTCONTROL} -q name="${_rtcFile}" -o "tracker")
        payloadDetails[PATH]="$(${_RTCONTROL} -q name="${_rtcFile}" -o path)"
        ;;

    "ARIA2")
        payloadDetails[HASH]=$1
        payloadDetails[KEY]="$(${_ARIA2} -S ${ACTIVE_TORRENT_FOLDER}/$1.torrent |grep "^Name:"|cut -d' ' -f 2- )"
        payloadDetails[LABEL]=$2
        payloadDetails[TRACKER]=$(${_ARIA2} -S ${ACTIVE_TORRENT_FOLDER}/$1.torrent |grep "Magnet URI"|cut -d\& -f 3-|sed "s/tr=//g")
        payloadDetails[PATH]="$payloadDetails[KEY]"
# If path by label
#       payloadDetails[PATH]="$payloadDetails[LABEL]/$payloadDetails[KEY]"
# Labels/Categories are not supported explicitedly by the torrent standard
        ;;

    "DELUGE")
        payloadDetails[HASH]=$1
        payloadDetails[KEY]="$2"
        payloadDetails[LABEL]=$(${_DELUGECONSOLE} "info -v"  $1 |grep "Label: "|cut -d' ' -f 2)
        payloadDetails[TRACKER]=$(${_DELUGECONSOLE} "info -v"  $1 |grep "Tracker: "|cut -d' ' -f 2-)
        payloadDetails[PATH]="$3"
        ;;


    "QBITTORRENT")
        payloadDetails[KEY]="$1"
        payloadDetails[HASH]=$2
        payloadDetails[LABEL]=$3
        payloadDetails[TRACKER]=$4
        payloadDetails[PATH]="$5"
        ;;
esac


function Main()
{

    local _event
    local _queued

    Invoke=${SECONDS}

    WaitLock

    CheckFields

    if [[ $? == 0 ]]
    then
        SetType

        _event=$(CreateQEvent "${payloadDetails[KEY]}" ${payloadDetails[HASH]} ${payloadDetails[TYPE]})
        _queued=$(PublishEvent "${QUEUE_CHANNEL}" "${_event}")

    else
        _queued=false
    fi

    MarkQueued ${_queued}

    LogEvent ${_queued}
}

function CheckFields()
{
    local _return=0

    if [[ ${numArgs}  -gt 0 ]]
    then
        if [[ ! -z "${payloadDetails[PATH]}" && -e "${payloadDetails[PATH]}" ]]
        then
            payloadDetails[KEY]="${payloadDetails[PATH]}"
        elif [[ -e "${payloadDetails[KEY]}" ]]
        then
            if [[ -z ${payloadDetails[HASH]} ]]
            then
                 payloadDetails[HASH]="NotUsed"
            fi
        else
            _return=1
        fi
    else
        _return=1
    fi

    return ${_return}
}


function WaitLock()
{
        # Wait
        exec 5>/tmp/lock
        flock 5
}

function SetType()
{
    local _type=""

    ## Determine TYPE Code

    grep -Ev '(#.*$)|(^$)' $TYPE_CODES >/tmp/scratchCodes

    while read -r field comptype value code assigned
    do
        case $comptype in
            "IS")
                if [[ "${payloadDetails[$field]}" == $value && ${_type}==$assigned ]]
                then
                    _type=$code
                fi
            ;;

            "CONTAINS")
                if [[ "${payloadDetails[$field]}" =~ (^.*"$value"*)  && ${_type}==$assigned ]]
                then
                    _type=$code
                fi
            ;;

            "NOT")
                if [[ "${payloadDetails[$field]}" != $value && ${_type}==$assigned ]]
                then
                    _type=$code
                fi
            ;;
        esac
    done </tmp/scratchCodes

    if [[ ${_type} == "" ]]
    then
        _type=$DEFAULT_TYPE
    fi

    payloadDetails[TYPE]=${_type}
}


function CreateQEvent()
{
        printf "%s\t%s\t%s\n" "${payloadDetails[PATH]}" ${payloadDetails[HASH]} ${payloadDetails[TYPE]}
}


function LogEvent()
{
        local _result
        local _elapsed=$(( ${SECONDS}-${Invoke} ))

        if [[ $1==0 ]]
        then
                _result="SUCCESS"
        else
                _result="FAIL"
        fi

        printf "%s: <%s> %s ( %s ) ( %s ) [%d secs]\n" "$(date)" ${_result} "${payloadDetails[KEY]}" "${payloadDetails[HASH]}" ${payloadDetails[TYPE]}  ${_elapsed} >> $SERVER_LOGFILE
}

function MarkQueued()
{
        local _sent=$1
        local _hash=${payloadDetails[HASH]}

    if [[ ${_hash} !=  "NotUsed"  || $LABELLING -eq 0 ]]
    then
        if [[ ${_sent} ]]
        then
            _label=$Q_LABEL
        else
            _label=$Q_FAILED
        fi

        _event=$(printf "%s\t%s\n" ${_hash} ${_label}  )

        PublishEvent ${LABEL_CHANNEL} "${_event}"
    fi

}


function PublishEvent()
{
    local _channel=$1
        local _event="$2"

        $PUBLISHER -h $BUS_HOST  -p $BUS_PORT -t ${_channel} -u $USER -P $PW -m "${_event}" -q 2

        echo $?
}

Main
