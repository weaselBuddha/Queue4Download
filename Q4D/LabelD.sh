#!/bin/bash
# vi: ts=4:sw=4:et

# Server Side: Process Label Events 

source ~/.Q4D/Q4Dconfig.sh
source ~/.Q4D/Q4Ddefines.sh

declare -a Event

function Main()
{
    local _ack_field

    while GetEvent
    do

        _ack_field=$(eval $_LABEL_TOOL)
        printf "%s: Transfer <%s> %s ( %s )\n" "$(date)" ${_ack_field} "${Event[LABEL_INDEX]}" ${Event[HASH_INDEX]}  >> ${SERVER_LOGFILE}
    done
}



function GetEvent()
{
    oldIFS=$IFS
    IFS=$'\t'

    Event=($($SUBSCRIBER -h $BUS_HOST -p $BUS_PORT  -t $LABEL_CHANNEL -u $USER -P $PW  -C 1  ))
    local result=$?

    IFS=$oldIFS

    return $result
}

Main

