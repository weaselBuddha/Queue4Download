#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Dserver.sh - Server (seedbox) definitions
#
# Requires Q4Dconfig.sh to be sourced first.
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this

## Type Code Logic File - type codes tell the client which directory the
## download should go into (TV, MOVIE, MUSIC, VIDEO, ...)
readonly TYPE_CODES=$Q4D_PATH/Types.config
# IF not set, default to:
readonly DEFAULT_TYPE="V"

