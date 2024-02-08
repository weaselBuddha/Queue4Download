#!/bin/bash
# vi: ts=4:sw=4:et

readonly SERVER_LOGFILE=$Q4D_PATH/queue.log
readonly _RTCONTROL=~/bin/rtcontrol

readonly _ARIA2=/usr/bin/aria2c

readonly _DELUGECONSOLE=/usr/bin/deluge-console

readonly PUBLISHER="/usr/bin/mosquitto_pub"
readonly SUBSCRIBER="/usr/bin/mosquitto_sub"

# Event Channel for Queueing and Labelling
readonly QUEUE_CHANNEL="Down"
readonly LABEL_CHANNEL="Label"

# Q Labels
readonly Q_LABEL="QUEUED"
readonly Q_FAIL="NOT_QD"

# ACK Labels
readonly ACK="DONE"
readonly NACK="NOPE"

# Event Index
readonly HASH_INDEX=0
readonly LABEL_INDEX=1
readonly NUM_FIELDS=3

# Configuration
readonly LFTP_SCRIPT=$Q4D_PATH/LFTPtransfer.sh
readonly CLIENT_LOG=$Q4D_PATH/process.log


# Broken on Debian 11 Bullseye
readonly HOSTKEYFIX="set sftp:auto-confirm yes"
