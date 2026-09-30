#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Dv2 installer
#
#   install.sh server  [--client=NAME]        run on the seedbox (repo present)
#   install.sh client [--seedbox=user@host]   run on the home server
#
# server steps:
#   1. select the torrent tool (or --client=NAME)
#   2. lay out common/ + server/ flat into ~/.Q4D/
#   3. verify the tool defines GetPayloadDetails + SetLabel
#   4. ask broker coordinates and the log mode (into Q4Dconfig.sh)
#   5. record the repo path in ~/.Q4D/.q4d-repo (for the client install)
#
# client steps:
#   1. resolve the seedbox (user@host)
#   2. generate the Q4D ssh key, install its public key on the seedbox
#   3. verify SFTP access to the seedbox (lftp)
#   4. pull the shared config + the client files over SFTP (lftp)
#   5. make the local config machine-local (Q4D_ROLE=client, flat-mode log file)
#   6. verify the MQTT broker (best effort)
#   7. walk the server's Types.config codes -> local destination directories
#   8. ask the LFTP settings, generate Q4Dclient.sh
#   9. sync the LABELLING switch with the seedbox
#   10. install the systemd units (processEvent, logDaemon)
#
# One-liner for the home server (prompts read the pipe's stdin, so every
# question takes its default - run install.sh from disk to answer them):
#   ssh you@seedbox 'cat ~/Queue4Download/Q4Dv2/install.sh' | bash -s client you@seedbox
#
# Style: single entrance, single exit - every function takes its inputs as
# arguments, prints its value on stdout (when any), returns 0/1, and has
# exactly one exit. Status lines (msg) go to stderr, so a captured function
# prints nothing but its value. No globals: the dest dir, the repo path, the
# key path and the seedbox are all passed by name. The entry functions
# (install_server, install_client) state their steps as numbered comments,
# one action each.

set -u

## --- small tools -----------------------------------------------------------------

## msg <text>
## Prints one indented status line on stderr (stdout is reserved for a
## function's value, which callers capture).
function msg()
{
    echo "  $*" >&2
}

## prompt <label> [default]
## Asks one question; prints the answer (capture with $()).
function prompt()
{
    local _answer
    local _label=$1
    local _default=${2:-}

    read -r -p "  ${_label} [${_default}]: " _answer

    if [[ -z "${_answer}" ]]
    then
        _answer=${_default}
    fi

    printf '%s' "${_answer}"
}

## require_opt <name> <args...>
## Extracts --name=VALUE from <args...>; prints it (empty when not given).
## Returns 1 (with an error on stderr) on any other option.
function require_opt()
{
    local _name=$1
    local _value=""
    local _rc=0
    shift

    while [[ $# -gt 0 ]]
    do
        case "$1" in
            "--${_name}="*) _value=${1#*=} ;;
            *)
                echo "  ERROR: unknown option: $1 (use --${_name}=<value>)" >&2
                _rc=1
                break
                ;;
        esac
        shift
    done

    if [[ ${_rc} -eq 0 ]]
    then
        printf '%s' "${_value}"
    fi

    return ${_rc}
}

## seedbox_user <seedbox>
## Prints the user part of a user@host seedbox.
function seedbox_user()
{
    printf '%s' "${1%%@*}"
}

## seedbox_host <seedbox>
## Prints the host part of a user@host seedbox.
function seedbox_host()
{
    printf '%s' "${1##*@}"
}

## --- transport (non-interactive ssh + lftp/sftp) -----------------------------------

## run_ssh <key> <seedbox> <command...>
## One non-interactive ssh command with the Q4D key. BatchMode: a prompt is
## a failure, not a hang.
function run_ssh()
{
    local _key=$1
    local _seedbox=$2
    shift 2

    ssh -i "${_key}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 "${_seedbox}" "$@"
}

## run_lftp <key> <seedbox> <command>
## One non-interactive lftp sftp session with the Q4D key - the same
## transport the client runtime (LFTPtransfer.sh) uses.
function run_lftp()
{
    local _key=$1
    local _seedbox=$2
    local _cmd=$3

    lftp -u "$(seedbox_user "${_seedbox}")" "sftp://$(seedbox_host "${_seedbox}")/" \
        -e "set sftp:auto-confirm yes; set sftp:ssh-key-file=${_key}; ${_cmd}; bye"
}

## key_auth_ok <seedbox> <key>
## True when passwordless ssh with the key works.
function key_auth_ok()
{
    run_ssh "$2" "$1" true
}

## install_pubkey <seedbox> <pubkey>
## Adds the public key to the seedbox's authorized_keys. This is the ONE
## step of the install that may ask for a password (key auth cannot work
## yet, by definition).
function install_pubkey()
{
    local _seedbox=$1
    local _pub=$2

    if command -v ssh-copy-id >/dev/null
    then
        ssh-copy-id -i "${_pub}" -o StrictHostKeyChecking=accept-new "${_seedbox}" > /dev/null
    else
        ssh -o StrictHostKeyChecking=accept-new "${_seedbox}" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
            < "${_pub}"
    fi
}

## setup_ssh <seedbox>
## Generates the Q4D key when missing and installs the public key when key
## auth does not work yet. Prints the key path.
function setup_ssh()
{
    local _seedbox=$1
    local _key="${HOME}/.ssh/id_ed25519_q4d"
    local _rc=1

    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"

    if [[ ! -f "${_key}" ]]
    then
        ssh-keygen -t ed25519 -N "" -C "q4d-$(hostname)" -f "${_key}" -q
        msg "ssh key generated: ${_key}"
    fi

    if key_auth_ok "${_seedbox}" "${_key}"
    then
        msg "key auth to $(seedbox_host "${_seedbox}"): ok"
        _rc=0
    elif install_pubkey "${_seedbox}" "${_key}.pub" && key_auth_ok "${_seedbox}" "${_key}"
    then
        msg "key auth to $(seedbox_host "${_seedbox}"): ok (public key installed)"
        _rc=0
    else
        msg "key auth to $(seedbox_host "${_seedbox}"): FAILED"
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        printf '%s' "${_key}"
    fi

    return ${_rc}
}

## --- server ------------------------------------------------------------------------

## set_config <file> <name> <value>
## Rewrites the "readonly NAME=..." line of <file>.
## (awk, not sed: the value is not replacement-escaped for &, |, \)
function set_config()
{
    local _file=$1
    local _name=$2
    local _value=$3

    awk -v key="${_name}" -v val="${_value}" '
        index($0, "readonly " key "=") == 1 { print "readonly " key "=\"" val "\""; next }
        { print }
    ' "${_file}" > "${_file}.tmp" \
        && mv "${_file}.tmp" "${_file}"
}

## set_config_remote <key> <seedbox> <name> <value>
## The set_config rewriter, run on the seedbox (for simple values, such as
## the booleans sync_labelling writes).
function set_config_remote()
{
    local _key=$1
    local _seedbox=$2
    local _name=$3
    local _value=$4

    run_ssh "${_key}" "${_seedbox}" \
        "awk -v key=\"${_name}\" -v val=\"${_value}\" 'index(\$0, \"readonly \" key \"=\") == 1 { print \"readonly \" key \"=\\\"\" val \"\\\"\"; next } { print }' ~/.Q4D/Q4Dconfig.sh > ~/.Q4D/Q4Dconfig.sh.tmp && mv ~/.Q4D/Q4Dconfig.sh.tmp ~/.Q4D/Q4Dconfig.sh"
}

## ask_tool <repo> <requested>
## Prints the torrent tool to install (prompts when <requested> is empty).
function ask_tool()
{
    local _repo=$1
    local _client=$2
    local _f

    if [[ -z "${_client}" ]]
    then
        echo "Available torrent tools:" >&2
        for _f in "${_repo}/server/torrenttools"/TorrentTool.*
        do
            [[ -e "${_f}" ]] || continue
            msg "${_f##*.}"
        done
        _client=$(prompt "torrent tool" "rtcontrol")
    fi

    printf '%s' "${_client}"
}

## lay_out_server <repo> <dest> <client>
## Flat layout: common/ + server/ into <dest>, tool selected by name.
function lay_out_server()
{
    local _repo=$1
    local _dest=$2
    local _client=$3

    mkdir -p "${_dest}"
    cp "${_repo}/common/"* "${_dest}"/
    cp "${_repo}/server/Q4Dserver.sh" "${_repo}/server/Queue4Download.sh" \
       "${_repo}/server/LabelD.sh" "${_repo}/server/Types.config" "${_dest}"/
    cp -r "${_repo}/server/torrenttools" "${_dest}"/
    cp -r "${_repo}/server/labellers" "${_dest}"/
    cp "${_repo}/server/torrenttools/TorrentTool.${_client}" "${_dest}/TorrentTool.sh"
    chmod +x "${_dest}/Queue4Download.sh" "${_dest}/LabelD.sh" "${_dest}/LogD.sh"
}

## check_tool <dest> <client>
## True when the installed tool defines both contract functions.
function check_tool()
{
    local _dest=$1
    local _client=$2

    bash -c "source '${_dest}/Q4Dconfig.sh'; source '${_dest}/TorrentTool.sh'; declare -F GetPayloadDetails SetLabel >/dev/null"
}

## install_server <repo> [--client=NAME]
## Lays out the seedbox.
function install_server()
{
    local _repo=$1
    shift
    local _dest="${HOME}/.Q4D"
    local _client=""
    local _requested=""
    local _logmode=""
    local _rc=0

    echo "Server install on $(hostname) -> ${_dest}"
    echo

    # 1. Select the torrent tool.
    _requested=$(require_opt client "$@") || _rc=1
    if [[ ${_rc} -eq 0 ]]
    then
        _client=$(ask_tool "${_repo}" "${_requested}") || _rc=1
    fi

    if [[ ${_rc} -eq 0 && ! -f "${_repo}/server/torrenttools/TorrentTool.${_client}" ]]
    then
        msg "no such tool: TorrentTool.${_client}"
        _rc=1
    fi

    # 2. Lay out the seedbox and record the selected tool.
    if [[ ${_rc} -eq 0 ]]
    then
        lay_out_server "${_repo}" "${_dest}" "${_client}" || _rc=1
    fi
    if [[ ${_rc} -eq 0 ]]
    then
        set_config "${_dest}/Q4Dconfig.sh" TORRENT_CLIENT "${_client}"
        msg "files laid out in ${_dest} (tool: ${_client})"
    fi

    # 3. The selected tool must define both contract functions.
    if [[ ${_rc} -eq 0 ]]
    then
        if check_tool "${_dest}" "${_client}"
        then
            msg "tool contract ok (GetPayloadDetails + SetLabel)"
        else
            msg "TorrentTool.${_client} does not define GetPayloadDetails + SetLabel"
            _rc=1
        fi
    fi

    # 4. Broker coordinates (the broker lives on the HOME server).
    if [[ ${_rc} -eq 0 ]]
    then
        set_config "${_dest}/Q4Dconfig.sh" BUS_HOST "$(prompt "broker host (home server IP, e.g. WireGuard)" "127.0.0.1")"
        set_config "${_dest}/Q4Dconfig.sh" BUS_PORT "$(prompt "broker port" "1883")"
        set_config "${_dest}/Q4Dconfig.sh" BUS_USER "$(prompt "MQTT username" "mosquitto_user")"
        set_config "${_dest}/Q4Dconfig.sh" BUS_PW "$(prompt "MQTT password" "mqtt_password")"
    fi

    # 5. Logging sink for the whole system (either/or; the client gets it
    #    with the copied Q4Dconfig.sh). This machine's role is recorded, and
    #    flat mode asks for this machine's log file (the client installer
    #    asks for its own).
    if [[ ${_rc} -eq 0 ]]
    then
        _logmode=$(prompt "log mode (flat file | bus)" "flat")
        set_config "${_dest}/Q4Dconfig.sh" LOG_MODE "${_logmode}"
        set_config "${_dest}/Q4Dconfig.sh" Q4D_ROLE "server"
        if [[ "${_logmode}" == "flat" ]]
        then
            set_config "${_dest}/Q4Dconfig.sh" SERVER_LOG "$(prompt "server log file" "${_dest}/queue.log")"
        fi
    fi

    # 6. Record the repo path - the client installer pulls client files from there.
    if [[ ${_rc} -eq 0 ]]
    then
        echo "${_repo}" > "${_dest}/.q4d-repo"
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        echo
        echo "Server installed: ${_dest} (torrent tool: ${_client})"
        echo
        echo "Hook / labelling instructions for this client:"
        sed -n '1,/^$/p' "${_dest}/TorrentTool.sh"
        echo
        echo "Then, on the HOME server, run:"
        echo "  ssh you@seedbox 'cat ${_repo}/install.sh' | bash -s client you@seedbox"
    fi

    return ${_rc}
}

## --- client --------------------------------------------------------------------------

## check_sftp <seedbox> <key>
## Verifies SFTP access to the seedbox with the key (lftp, exactly as the
## runtime transfer engine connects).
function check_sftp()
{
    local _seedbox=$1
    local _key=$2
    local _rc=0

    run_lftp "${_key}" "${_seedbox}" "ls" > /dev/null || _rc=1

    if [[ ${_rc} -eq 0 ]]
    then
        msg "sftp access to $(seedbox_host "${_seedbox}"): ok"
    else
        msg "sftp access to $(seedbox_host "${_seedbox}"): FAILED (check key auth and the sftp subsystem)"
    fi

    return ${_rc}
}

## find_seedbox_repo <seedbox> <key>
## Prints the seedbox's repo path (recorded by 'install.sh server').
function find_seedbox_repo()
{
    local _seedbox=$1
    local _key=$2
    local _repo
    local _rc=0

    _repo=$(run_ssh "${_key}" "${_seedbox}" 'cat ~/.Q4D/.q4d-repo 2>/dev/null')

    if [[ -z "${_repo}" ]]
    then
        _rc=1
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        printf '%s' "${_repo}"
    fi

    return ${_rc}
}

## copy_client_files <seedbox> <repo> <dest> <key>
## Pulls the live shared config from the seedbox and the client files
## (including the .service units) from its repo - over SFTP (lftp), the
## transport the client code already requires.
function copy_client_files()
{
    local _seedbox=$1
    local _repo=$2
    local _dest=$3
    local _key=$4
    local _rc=0

    mkdir -p "${_dest}"

    run_lftp "${_key}" "${_seedbox}" \
        "lcd \"${_dest}\"; get ~/.Q4D/Q4Dconfig.sh ~/.Q4D/Q4Ddefines.sh ~/.Q4D/Q4Dlib.sh ~/.Q4D/LogD.sh" || _rc=1
    run_lftp "${_key}" "${_seedbox}" \
        "mirror -R \"${_repo}/client\" \"${_dest}\"" || _rc=1

    if [[ ${_rc} -eq 0 ]]
    then
        chmod +x "${_dest}/ProcessEvent.sh" "${_dest}/LFTPtransfer.sh" "${_dest}/LogD.sh"
    fi

    return ${_rc}
}

## check_broker <dest>
## Verifies the MQTT broker with the installed credentials (best effort:
## a failure is reported but never stops the install).
function check_broker()
{
    local _dest=$1
    local _vals=()
    local _bhost
    local _bport
    local _buser
    local _bpw
    local _rc=0

    mapfile -t _vals < <(bash -c "source '${_dest}/Q4Dconfig.sh'; printf '%s\n' \"\$BUS_HOST\" \"\$BUS_PORT\" \"\$BUS_USER\" \"\$BUS_PW\"")
    _bhost="${_vals[0]:-}"
    _bport="${_vals[1]:-}"
    _buser="${_vals[2]:-}"
    _bpw="${_vals[3]:-}"

    if ! command -v mosquitto_pub >/dev/null
    then
        msg "broker: mosquitto_pub not found - skipping"
    elif mosquitto_pub -h "${_bhost}" -p "${_bport}" -u "${_buser}" -P "${_bpw}" -t "Q4D/install/check" -m ok -q 1
    then
        msg "broker: ok (${_bhost}:${_bport}, auth ok)"
    else
        msg "broker: FAILED (${_bhost}:${_bport}) - broker down or bad credentials (continuing)"
        _rc=1
    fi

    return ${_rc}
}

## collect_type_codes <seedbox> <key>
## Prints every type code the server knows (its Types.config, plus its
## DEFAULT_TYPE), deduplicated, one per line.
function collect_type_codes()
{
    local _seedbox=$1
    local _key=$2

    # One round trip: the codes, then the default; the final sort -u drops a
    # duplicate default.
    # shellcheck disable=SC2016  # remote shell code; \$4 and the quotes are deliberate
    run_ssh "${_key}" "${_seedbox}" \
        'grep -Ev "^(#|\s*$)" ~/.Q4D/Types.config | awk "{print \$4}" | sort -u; grep "^DEFAULT_TYPE=" ~/.Q4D/Q4Dserver.sh | cut -d"\"" -f2' \
        | sort -u
}

## default_dir_for <code>
## Prints the conventional destination for a well-known code (empty for the
## rest - an empty answer falls through to ERR at transfer time).
function default_dir_for()
{
    local _dir=""

    case $1 in
        T) _dir="/Media/TV" ;;
        M) _dir="/Media/Movies" ;;
        A) _dir="/Media/Music" ;;
        B) _dir="/Media/B-Movies" ;;
        V) _dir="/Media/Video" ;;
        J) _dir="/Media/Jeopardy" ;;
    esac

    printf '%s' "${_dir}"
}

## build_type_code_map <codes>
## Steps through the server's codes, prompts for a destination per code
## (conventional default offered), creates the directories, and prints the
## TypeCodes map body (lines of [CODE]="DIRECTORY") with ERR last.
## The codes are read on fd 3: a read on stdin inside the loop would
## otherwise swallow the code lines instead of the typed answers.
function build_type_code_map()
{
    local _map=""
    local _code
    local _dir

    while read -r _code <&3
    do
        if [[ -n "${_code}" ]]
        then
            _dir=$(prompt "code ${_code} destination" "$(default_dir_for "${_code}")")
            if [[ -n "${_dir}" ]]
            then
                _map="${_map}        [${_code}]=\"${_dir}\"
"
                mkdir -p "${_dir}" 2>/dev/null
            else
                msg "  (no directory for code ${_code} - falls through to ERR)"
            fi
        fi
    done 3<<< "$1"

    _dir=$(prompt "code ERR destination (catch-all)" "/Media/Other")
    _map="${_map}        [ERR]=\"${_dir}\"
"

    printf '%s' "${_map}"
}

## generate_client_config <dest> <key> <map> <host> <creds> <threads> <segments>
## Writes <dest>/Q4Dclient.sh from the answered settings. The generated
## HOSTKEYFIX points lftp at the Q4D key, so the runtime transfer needs no
## password at all (CREDS is only a fallback).
function generate_client_config()
{
    local _dest=$1
    local _key=$2
    local _map=$3
    local _host=$4
    local _creds=$5
    local _threads=$6
    local _segments=$7

    cat > "${_dest}/Q4Dclient.sh" <<EOF
#!/bin/bash
# vi: ts=4:sw=4:et
# Q4Dclient.sh - Client (home server) definitions
# Generated by install.sh client on $(date). Requires Q4Dconfig.sh first.
# shellcheck disable=SC2034  # constants are consumed by the scripts that source this

readonly LFTP_SCRIPT=\$Q4D_PATH/LFTPtransfer.sh

# sftp: auto-confirm the host key and use the Q4D key the installer created
readonly HOSTKEYFIX="set sftp:auto-confirm yes; set sftp:ssh-key-file ${_key}"

readonly THREADS=${_threads}
readonly SEGMENTS=${_segments}
readonly CREDS='${_creds}'
readonly HOST="${_host}"

# Type Code to Destination Directory Map: [CODE]="DIRECTORY"
# Don't Remove ERR as last entry
declare -Ag TypeCodes=(
${_map})
EOF
    chmod +x "${_dest}/Q4Dclient.sh"
}

## sync_labelling <seedbox> <dest> <key>
## Asks whether to label on completion; keeps both sides in agreement.
function sync_labelling()
{
    local _seedbox=$1
    local _dest=$2
    local _key=$3
    local _srvlabel
    local _labelling
    local _rc=0

    _srvlabel=$(run_ssh "${_key}" "${_seedbox}" \
        "bash -c 'source ~/.Q4D/Q4Dconfig.sh; printf \"%s\" \$LABELLING'")
    _labelling=$(prompt "label torrent on completion (DONE/NOPE)? (server has: ${_srvlabel:-true})" "${_srvlabel:-true}")

    set_config "${_dest}/Q4Dconfig.sh" LABELLING "${_labelling}" || _rc=1

    if [[ ${_rc} -eq 0 && "${_labelling}" != "${_srvlabel:-true}" ]]
    then
        set_config_remote "${_key}" "${_seedbox}" LABELLING "${_labelling}" || _rc=1
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        msg "LABELLING: ${_labelling} (both sides in agreement)"
    fi

    return ${_rc}
}

## install_unit <dest> <name>
## Installs and enables <dest>/<name>.service for the invoking user.
## The unit is the copy pulled into <dest> (the repo copy does not exist
## when install.sh arrives over a pipe).
function install_unit()
{
    local _dest=$1
    local _name=$2
    local _unit="${_dest}/${_name}.service"
    local _unitdest="/etc/systemd/system/${_name}.service"
    local _user
    local _rc=1

    _user=$(id -un)

    if [[ ${EUID} -eq 0 ]]
    then
        cp "${_unit}" "${_unitdest}" && \
        sed -i "s|^User=.*|User=${_user}|" "${_unitdest}" && \
        systemctl daemon-reload && \
        systemctl enable "${_name}.service" && \
        _rc=0
    elif command -v sudo >/dev/null
    then
        sudo cp "${_unit}" "${_unitdest}" && \
        sudo sed -i "s|^User=.*|User=${_user}|" "${_unitdest}" && \
        sudo systemctl daemon-reload && \
        sudo systemctl enable "${_name}.service" && \
        _rc=0
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        msg "${_name}.service: installed and enabled (User=${_user})"
    else
        msg "${_name}.service: install manually:"
        msg "  cp ${_unit} ${_unitdest}   # then set User=${_user}, daemon-reload, enable"
    fi

    return ${_rc}
}

## install_systemd_units <dest>
## Installs the client-side daemons. (The same logDaemon unit can be
## installed on the seedbox too, for a central log there as well.)
function install_systemd_units()
{
    local _dest=$1
    local _rc=0

    install_unit "${_dest}" processEvent || _rc=1
    install_unit "${_dest}" logDaemon || _rc=1

    return ${_rc}
}

## step <fatal|warn> <command...>
## Runs one single-command install step.
##   fatal - the command's status propagates (pair it with `|| _rc=1`)
##   warn  - best effort: the command reports the failure itself and the
##           install continues (returns 0)
function step()
{
    local _mode=$1
    shift
    local _rc=0

    "$@" || _rc=1

    if [[ ${_mode} == warn ]]
    then
        _rc=0
    fi

    return ${_rc}
}

## install_client [--seedbox=user@host]
## Lays out the home server.
function install_client()
{
    local _dest="${HOME}/.Q4D"
    local _seedbox=""
    local _key=""
    local _repo=""
    local _codes=""
    local _map=""
    local _host
    local _creds
    local _threads
    local _segments
    local _logmode=""
    local _rc=0

    echo "Client install on $(hostname) -> ${_dest}"
    echo

    # 1. Resolve the seedbox (user@host).
    _seedbox=$(require_opt seedbox "$@") || _rc=1
    if [[ ${_rc} -eq 0 && -z "${_seedbox}" ]]
    then
        _seedbox=$(prompt "seedbox (user@host)" "")
    fi
    if [[ ${_rc} -eq 0 && "${_seedbox}" != *@* ]]
    then
        msg "seedbox must be user@host"
        _rc=1
    fi

    # 2. Q4D ssh key: generate it, install its public key on the seedbox.
    if [[ ${_rc} -eq 0 ]]
    then
        _key=$(setup_ssh "${_seedbox}") || _rc=1
    fi

    # 3. Verify SFTP access to the seedbox.
    if [[ ${_rc} -eq 0 ]]
    then
        step fatal check_sftp "${_seedbox}" "${_key}" || _rc=1
    fi

    # 4. Pull the shared config + client files over SFTP.
    if [[ ${_rc} -eq 0 ]]
    then
        _repo=$(find_seedbox_repo "${_seedbox}" "${_key}") || _rc=1
    fi
    if [[ ${_rc} -eq 0 ]]
    then
        msg "repo on seedbox: ${_repo}"
        copy_client_files "${_seedbox}" "${_repo}" "${_dest}" "${_key}" || _rc=1
    fi

    # 5. Make the local config machine-local: the client role, and - in flat
    #    mode - this machine's log file (the pulled copy carries the seedbox's).
    if [[ ${_rc} -eq 0 ]]
    then
        set_config "${_dest}/Q4Dconfig.sh" Q4D_ROLE "client" || _rc=1
    fi
    if [[ ${_rc} -eq 0 ]]
    then
        _logmode=$(bash -c "source '${_dest}/Q4Dconfig.sh'; printf '%s' \"\$LOG_MODE\"")
        if [[ "${_logmode}" == "flat" ]]
        then
            set_config "${_dest}/Q4Dconfig.sh" CLIENT_LOG "$(prompt "client log file" "${_dest}/process.log")" || _rc=1
        fi
    fi

    # 6. Verify the MQTT broker (best effort - a failure only warns).
    if [[ ${_rc} -eq 0 ]]
    then
        step warn check_broker "${_dest}"
    fi

    # 7. Walk the server's type codes; define a local directory for each.
    if [[ ${_rc} -eq 0 ]]
    then
        echo
        echo "Type codes on the server -> destination directories on THIS machine:"
        _codes=$(collect_type_codes "${_seedbox}" "${_key}") || _rc=1
    fi
    if [[ ${_rc} -eq 0 ]]
    then
        _map=$(build_type_code_map "${_codes}") || _rc=1
    fi

    # 8. LFTP settings -> Q4Dclient.sh.
    if [[ ${_rc} -eq 0 ]]
    then
        _host=$(prompt "LFTP host (seedbox as seen from home)" "$(seedbox_host "${_seedbox}")")
        _creds=$(prompt "LFTP credentials (user:password; fallback when key auth is off)" "")
        _threads=$(prompt "LFTP parallel threads" "5")
        _segments=$(prompt "LFTP pget segments" "4")
        generate_client_config "${_dest}" "${_key}" "${_map}" "${_host}" "${_creds}" "${_threads}" "${_segments}" || _rc=1
    fi

    # 9. Keep the labelling switch in agreement with the seedbox.
    if [[ ${_rc} -eq 0 ]]
    then
        step fatal sync_labelling "${_seedbox}" "${_dest}" "${_key}" || _rc=1
    fi

    # 10. Install the systemd units (best effort - hints when it cannot).
    if [[ ${_rc} -eq 0 ]]
    then
        step warn install_systemd_units "${_dest}"
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        echo
        echo "Client installed: ${_dest} (seedbox: ${_seedbox})"
    fi

    return ${_rc}
}

## --- entry point -----------------------------------------------------------------------

## main <mode> [options...]
## Resolves the repo path once and dispatches; the script's exit code is
## main's return value.
function main()
{
    local _mode=${1:-}
    local _rc=0

    # shellcheck disable=SC2164  # cd in a subshell; the && propagates its status
    # _repo is only used by the server mode (in pipe mode, 'bash -s', it
    # resolves to the CWD, which is never used).
    local _repo
    _repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

    case "${_mode}" in
        server) shift; install_server "${_repo}" "$@" || _rc=1 ;;
        client) shift; install_client "$@" || _rc=1 ;;
        *)
            echo "Usage: $0 server [--client=NAME]"
            echo "       $0 client [--seedbox=user@host]"
            _rc=1
            ;;
    esac

    return ${_rc}
}

main "$@"
