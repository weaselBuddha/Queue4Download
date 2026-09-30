#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Dclient.sh - Client (home server) definitions
#
# TEMPLATE: 'install.sh client' pulls this file and then overwrites it in
# ~/.Q4D/ with the configuration it generates. Kept as the documented default.
#
# Requires Q4Dconfig.sh to be sourced first.
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this

# Transfer engine (client-side; the log file is CLIENT_LOG in Q4Dconfig.sh)
readonly LFTP_SCRIPT=$Q4D_PATH/LFTPtransfer.sh

# Broken on Debian 11 Bullseye
readonly HOSTKEYFIX="set sftp:auto-confirm yes"

## LFTP Throttle
readonly THREADS=5
readonly SEGMENTS=4

## LFTP Login (Home->Seedbox) Values (alternatively use .netrc or set up ssh keys instead)
readonly CREDS='user:password'

## Your Server (as reachable from home - usually the WireGuard IP)
readonly HOST="your.seedbox.ip"

# Type Code to Destination Directory Map: [CODE]="DIRECTORY"
# Don't Remove ERR as last entry
declare -Ag TypeCodes=\
(
        [A]="/Media/Music"
        [B]="/Media/B-Movies"
        [J]="/Media/Jeopardy"
        [T]="/Media/TV"
        [M]="/Media/Movies"
        [V]="/Media/Video"
        [ERR]="/Media/Other"
)
