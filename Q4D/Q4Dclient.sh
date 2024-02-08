#!/bin/bash
# vi: ts=4:sw=4:et
# Associate Array, type code -> destination directory


# LFTP Throttle
readonly THREADS=5
readonly SEGMENTS=4

# LFTP Login (Home->Seedbox) Values (alternatively use .netrc or set up ssh keys instead)
readonly CREDS='fear:loathing'

# Your Server
readonly HOST="vegas.seedbox.net"


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

# Event Indexes
readonly FILENAME=0
readonly HASH=1
readonly TYPE=2
