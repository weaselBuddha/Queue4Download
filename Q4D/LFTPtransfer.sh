#!/bin/bash
#set -xv  # debugging

# Please Change
readonly USER="dummy"
readonly PW="dummyPW"


# LFTP Values
readonly CREDS='dummy:dummyPW'
readonly HOST="owner.chmuranet.net"
readonly BASE="/home/owner/Downloads/"
readonly THREADS=3
readonly SEGMENTS=3
readonly HOSTKEYFIX="set sftp:auto-confirm yes"

## Event Bus (for ACK)
readonly PUBLISHER="/usr/bin/mosquitto_pub"
readonly BUS_HOST="testbed.chmuranet.com"
readonly BUS_PORT=1883
readonly CHANNEL="ACK"
readonly OTHER_PARMS="-q 2"


readonly LOGFILE=~/Process.log

declare -A TypeCodes=\
(
	[A]="/NAS/POST"
	[T]="/NAS/justDown/TV"
	[M]="/NAS/justDown/Movies"
	[V]="/NAS/Video"
	[ERR]="/NAS/Other"
)


function Main()
{
	local _result
	
	local _target="$1"
	local _hash=$2
	local _where2=$3


	WaitLock

	SetDirectory ${_where2}

	_result=$(TransferPayload "${_target}")

	ProcessResult ${_result} "${_target}" ${_hash}

}

function WaitLock()
{
    # Wait
    exec 5>/tmp/lock
    flock 5
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
	lftp -u ${CREDS} sftp://${HOST}/  -e "$HOSTKEYFIX; cd $BASE ; mirror -c  --parallel=$THREADS --use-pget-n=$SEGMENTS \"${_target}\" ;quit" >>/tmp/fail$$.log 2>&1 

	_transferred=$?

	if [[ $_transferred -ne 0 ]]
	then
            # Now as a file
        	lftp -u ${CREDS} sftp://${HOST}/  -e "$HOSTKEYFIX;cd ${BASE} ; pget -n $SEGMENTS \"${_target}\" ;quit" >>/tmp/fail$$.log 2>&1 
        	_transferred=$?
	fi

	echo ${_transferred}
}

function ProcessResult()
{
	local _result=$1
	local _target="$2"
	local _hash=$3
    local _event
	

	if [[ ${_result} -eq 0  ]]
	then
        # ACK
       	echo $(date)": Transfer of ${_target} Completed." >> $LOGFILE

        _event=$(printf "%s +\n" ${_hash})
    else
        # NACK
        echo $(date)": Transfer of ${_target} Failed." >> $LOGFILE
     	cat /tmp/fail$$.log >> $LOGFILE
        
        _event=$(printf "%s #\n" ${_hash})
    
    fi

    if [ ${_hash} != "0000" ]
    then
        $PUBLISHER -h $BUS_HOST  -p $BUS_PORT -t $CHANNEL -u $USER -P $PW -m "${_event}" $OTHER_PARMS

   	    if [[ $? -eq 0 ]]
   	    then
            echo $(date)": Event ACKED for "${_hash} >> $LOGFILE
   	    else
        	echo $(date)": ACK Failed for "${_hash} >> $LOGFILE
   		fi
    fi
}

Main "$1" $2 $3

