#!/bin/bash
# vi: ts=4:sw=4:et
exec 2>&1 >>~/Events.log

declare -a Event

source ~/.Q4D/Q4Dconfig.sh
source ~/.Q4D/Q4Ddefines.sh
source ~/.Q4D/Q4Dclient.sh

function Main()
{
        while GetEvent
        do
        echo $(date)": Event received for "${Event[$FILENAME]}" "${Event[$HASH]} "/ " ${Event[$TYPE]} >> $CLIENT_LOG


        if [[ ${#Event[@]} -eq NUM_FIELDS ]]
        then
                # Spawn transfer process
                $LFTP_SCRIPT "${Event[$FILENAME]}" ${Event[$HASH]} ${Event[$TYPE]} 2>>$CLIENT_LOG &
        else
            echo $(date)": Event Malformed, " ${#Event[@]} " Elements - Discarded "  >> $CLIENT_LOG
        fi
        done
}

GetEvent()
{
    oldIFS=$IFS
    IFS=$'\t'

    # Blocks, Waiting
    Event=($($SUBSCRIBER -h $BUS_HOST -p $BUS_PORT  -t $QUEUE_CHANNEL -u $USER -P $PW  -C 1  ))
    local _result=$?

    IFS=$oldIFS
        echo ${Event[@]}

    return $_result
}


Main

echo $0 FAILED >> $CLIENT_LOG
