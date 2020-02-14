#!/bin/bash

readonly HASH=0
readonly ACK_FIELD=1
readonly USER=dummy
readonly PW=dummyPW

readonly SUBSCRIBER=/usr/bin/mosquitto_sub
readonly BUS_HOST=testbed.chmuranet.com
readonly BUS_PORT=1883
readonly CHANNEL=ACK
readonly OTHER_PARMS='-C 1'

readonly RTCONTROL=/home/owner/bin/rtcontrol
readonly ACK=DONE
readonly NACK=OOPS
readonly SET_LABEL="--custom 1"
readonly ACK_VALUE="+"
readonly LOGFILE=~/Queue.log

declare -a Event

function Main()
{
    local _ack_field
    local _name

    while GetEvent
    do
        if [[ ${Event[$ACK_FIELD]} == $ACK_VALUE ]]
        then
            $RTCONTROL  hash=${Event[$HASH]} $SET_LABEL=$ACK 
            _ack_field=$ACK
        else
            $RTCONTROL  hash=${Event[$HASH]} $SET_LABEL=$NACK 
            _ack_field=$NACK
        fi
        
        _name=$($RTCONTROL  -q hash="${Event[$HASH]}" -o name )

        printf "%s: Transfer <%s> %s ( %s )\n" "$(date)" ${_ack_field} "${_name}" ${Event[HASH]}  >> ${LOGFILE}
    done
}



function GetEvent()
{
        oldIFS=$IFS
        IFS=$' '

        Event=($($SUBSCRIBER -h $BUS_HOST $OTHER_PARMS  -p $BUS_PORT  -t $CHANNEL -u $USER -P $PW  ))
        local result=$?

        IFS=$oldIFS

        return $result
}

Main

