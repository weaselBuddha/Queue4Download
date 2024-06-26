#!/bin/bash
# vi: ts=4:sw=4:et

source ~/.Q4D/Q4Dconfig.sh
source ~/.Q4D/Q4Ddefines.sh
source ~/.Q4D/Q4Dclient.sh


function Main()
{
        local _target="$1"
        local _hash=$2
        local _where2=$3

        WaitLock

        if SetDirectory ${_where2}
        then
                TransferPayload "${_target}"

                ProcessResult $? "${_target}" ${_hash}
        else
                echo $(date)" Destination Bad: ${_where2}" >> $CLIENT_LOG
        fi
}

# Bash Lock Function, Single Transfer at a time
function WaitLock()
{
    # Wait/Block
    exec 5>/tmp/lock
    flock 5
    # Lock Released After Script Completes
}

function SetDirectory()
{
        local _destination=${TypeCodes[$1]:-${TypeCodes[ERR]}}

        cd ${_destination}
}



function TransferPayload()
{
        local _target="$1"
        local _transferred

        umask 0

    # Try to grab as a directory
        lftp -u ${CREDS} sftp://${HOST}/  -e "$HOSTKEYFIX; mirror -c  --parallel=$THREADS --use-pget-n=$SEGMENTS \"${_target}\" ;quit" >>/tmp/fail$$.log 2>&1

        _transferred=$?

        if [[ $_transferred -ne 0 ]]
        then
        # Now as a file
        lftp -u ${CREDS} sftp://${HOST}/  -e "$HOSTKEYFIX; pget -n $THREADS \"${_target}\" ;quit" >>/tmp/fail$$.log 2>&1
        _transferred=$?
        fi

        base=$(basename "${_target}")
        echo base: "$base" . target: "${_target}"  >> $CLIENT_LOG
        chmod -R 777 "$base"


        return ${_transferred}
}


function PublishEvent()
{
    local _channel=$1
    local _event="$2"

    $PUBLISHER -h $BUS_HOST  -p $BUS_PORT -t ${_channel} -u $USER -P $PW -m "${_event}" -q 2

    echo $?
}

function ProcessResult()
{
        local _result=$1
        local _target="$2"
        local _hash=$3
        local _event

    if [[ $LABELLING -eq 0  && ${_hash} != "NotUsed" ]]
    then
        if [[ ${_result} == 0 ]]
        then
            _label=$ACK
                echo $(date)": Transfer of ${_target} Completed." >> $CLIENT_LOG
        else
                echo $(date)": Transfer of ${_target} Failed." >> $CLIENT_LOG
            _label=$NACK
                cat /tmp/fail$$.log >> $CLIENT_LOG
        fi

        _event=$(printf "%s\t%s\n" ${_hash} ${_label}  )

        PublishEvent ${LABEL_CHANNEL} "${_event}"

                if [[ $? ]]
                then
                        _pub="Succeeded"
                else
                        _pub="Failed"
                fi

                echo $(date)": Publish of Label Event for ${_target} Set to ${_label} ${_pub}" >> $CLIENT_LOG
    fi

}


Main "$1" $2 $3
