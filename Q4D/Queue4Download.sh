#!/bin/bash


declare -A payloadDetails

readonly _RTCONTROL=~/bin/rtcontrol

readonly ACTIVE_TORRENT_FOLDER=~/.session
readonly LOGFILE=~/Queue.log

## Event Bus
readonly PUBLISHER="/usr/bin/mosquitto_pub"
readonly BUS_HOST="testbed.chmuranet.com"
readonly BUS_PORT=1883
readonly CHANNEL="Down"
readonly OTHER_PARMS="-q 2"

# Please Change
readonly USER="dummy"
readonly PW="dummyPW"

readonly Q_LABEL="QUEUED"
readonly NO_EVENT="0"

function Main()
{
	local _payload="$1"
	local _event
	local _queued="1" # Default Not Queued`	

	Invoke=${SECONDS}

	WaitLock

	payloadDetails[KEY]="${_payload}"

	payloadDetails[HASHVAL]=$(GetTorrentHash "${_payload}")

	payloadDetails[TYPE]=$(SetType "${_payload}")

	if [[ ${payloadDetails[TYPE]} != $NO_EVENT ]]
	{
		_event="$(CreateEvent)"

		_queued=$(PublishEvent "${_event}")

		MarkQueued ${_queued}
	}
	
	LogEvent ${_queued}
}

function WaitLock()
{
	# Wait 
	exec 5>/tmp/lock
	flock 5
}

 
	
function GetTorrentField()
{
	local _rtcFile=$(echo "$1"|tr  [\]\[\,] [????])
	local _field=$2
	local _default=$3

	local _value=$(${_RTCONTROL}  -q name="${_rtcFile}" -o  ${_field}) 

	if [ -z ${_value} ]
	then
	     _value=${_default}
	fi

	echo ${_value}
}
	

function GetTorrentHash()
{
	local _payload="$1"
	local _rtcFile="$(echo ${_payload}|tr  [\]\[\,] [????])"
	local _hash
	local _tfile


	
	_hash=$(${_RTCONTROL} -q name="${_rtcFile}" -o "hash")
	
	if [ -z ${_hash} ]
	then
		_tfile=$(grep -l "${_payload@Q}" ${ACTIVE_TORRENT_FOLDER}/*.torrent)

       	if [[  $_tfile ]]
       	then    
        	_hash=$(basename ${TFILE} .torrent)
       	else
		_hash="0000"
           	echo $(date) ": ${_payload} Hash Not Found." >>${LOGFILE}
       	fi
	fi

	echo ${_hash}
}

function SetType()
{
	local _payload="$1"
	local _type="V"  # Default Video (something other than plex indexed)

	## Determine TYPE Code

	payloadDetails[LABEL]=$(GetTorrentField "${_payload}" "custom_1" "UNSET")
	payloadDetails[TRACKER]=$( GetTorrentField "${_payload}"  "tracker" "UNSET")
	payloadDetails[TRAIT]=$(GetTorrentField "${_payload}" "traits" "%")

	if [[ ${payloadDetails[LABEL]} == "FREE_LEECH" ]]  # Don't Automatically Download
	then
		_type="0"
	elif [[ ${payloadDetails[LABEL]} == "TV" ]]  # Sonarr, SickChill, Medusa - Destination app processing directory
	then
		_type="A"
	elif [[ ${payloadDetails[TRACKER]} =~ (^.*landof*)  || "${_payload}" =~ (^.*)(\.[sS][0-9]*[Ee][0-9]*) ]]
	then
        	_type="T"  # TV
	elif [[ ${payloadDetails[TRAIT]} =~  (^movie*) ||  ${payloadDetails[TRACKER]} =~ (^.*popcorn*) || "${_payload}" =~ (^.*x0r*) ]]
	then
        	_type="M"  # Movie
	fi
	
	echo ${_type}

}

function CreateEvent()
{
	printf "%s\t%s\t%s\n" "${payloadDetails[KEY]}" ${payloadDetails[HASHVAL]} ${payloadDetails[TYPE]}
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
	_type=${payloadDetails[TYPE]}
	
	printf "%s: <%s> %s ( %s ) ( %s ) [%d secs]\n" "$(date)" ${_result} "${payloadDetails[KEY]}" "${payloadDetails[HASHVAL]}" ${payloadDetails[TYPE]}  ${_elapsed} >> ${LOGFILE}
}

function MarkQueued()
{
	local _sent=$1
	local _hash=${payloadDetails[HASHVAL]}

        if [[ ${_hash} !=  "0000" && _sent==0 ]]
        then
            ${_RTCONTROL} -q hash=${_hash} --custom 1=$Q_LABEL
        fi
}


function PublishEvent()
{
	local _event="$1"

	$PUBLISHER -h $BUS_HOST  -p $BUS_PORT -t $CHANNEL -u $USER -P $PW -m "${_event}" $OTHER_PARMS
	
	echo $?
}

Main "$1"
