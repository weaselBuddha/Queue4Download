#!/bin/bash

declare -a Event

# Constants

readonly BUS_PATH="/usr/bin/mosquitto_sub"
readonly NUM_FIELDS=3

readonly FILENAME=0
readonly HASH=1
readonly TYPE=2

# Configuration
readonly LFTP_SCRIPT=/home/owner/Scripts/LFTPtransfer.sh
readonly SERVER="owner.chmuranet.net"

# MQTT
readonly QSERVER="testbed.chmuranet.com"
readonly QPORT=1883
readonly QUSER="dummy"
readonly QPW='dummyPW'
readonly CHANNEL="Down"

#logging
readonly LOGFILE="/home/owner/Process.log"
exec >> $LOGFILE 




function Main()
{
	while GetEvent
	do
        	echo $(date)": Event received for "${Event[$FILENAME]}" "${Event[$HASH]} "/ " ${Event[$TYPE]} >> $LOGFILE


        	if [[ ${#Event[@]} -eq NUM_FIELDS ]]
       		then
			# Spawn transfer process
               		LFTP_SCRIPT "${Event[$FILENAME]}" ${Event[$HASH]} ${Event[$TYPE]} 2>>$LOGFILE &
        	else
               		echo $(date)": Event Malformed, " ${#Event[@]} " Elements - Discarded "  >> $LOGFILE
        	fi
	done
}

GetEvent()
{
        oldIFS=$IFS
        IFS=$'\t'

	    # Blocks, Waiting
        Event=($($BUS_PATH -h "$QSERVER" -C 1  -p $QPORT  -t "$CHANNEL" -u $QUSER -P "$QPW"  -q 2 -c -i 2)) 2>> $LOGFILE
        local _result=$?

        IFS=$oldIFS

        return $_result
}


Main
echo FAIL
