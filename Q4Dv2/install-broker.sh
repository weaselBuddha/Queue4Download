#!/bin/bash
# vi: ts=4:sw=4:et
#
# Q4Dv2 broker installer - run on the SEEDBOX (the broker lives there,
# assumed NOT behind a NAT: the home server reaches it directly, so the
# listener binds the network address, not 127.0.0.1).
#
#   install-broker.sh [--tarball=PATH-OR-URL]
#
# --tarball=  local path (or URL) of the static mosquitto tarball built by
#             .github/workflows/mosquitto-static.yml. Default: the pinned
#             GitHub release (override the URL with MOSQUITTO_STATIC_URL).
#             Only used when the static install is needed.
#
# The static tarball is installed ONLY when no mosquitto broker is present
# and the distro package cannot be used (no sudo, or no package):
#   broker absent + sudo      -> distro package, configured in /etc/mosquitto
#   broker absent, no sudo    -> static tarball into ~/.Q4D/mosquitto,
#                                daemon via a systemd user unit or cron
#   broker present + sudo     -> configured in /etc/mosquitto (original
#                                config backed up), service restarted
#   broker present, no sudo   -> missing client tools come from the static
#                                tarball (the broker itself is left alone),
#                                client config + broker.conf written, manual
#                                steps printed for /etc/mosquitto
#
# steps:
#   1. detect an existing mosquitto (nothing is installed when there is one)
#   2. install the missing broker/tools (package, else static)
#   3. ask the bind address (default: the network address) and the port
#   4. credentials: username/password (mosquitto_passwd) or TLS client
#      certificates (self-generated CA) - generated in the user dir
#   5. write mosquitto.conf for the chosen mode (the user dir for a static
#      install; /etc/mosquitto, backed up, with the credentials copied to
#      /etc/mosquitto/q4d, for a package install)
#   6. write the mosquitto_pub/sub client config files - the credentials
#      then live in the file (600), never on a command line
#   7. run the daemon: the distro service when root/sudo, a systemd user
#      unit or cron @reboot+keepalive (flock) when not (best effort)
#   8. verify: a publish through the broker with the config-file auth
#      (best effort - a failure warns, it never stops the install)
#   9. write ~/.Q4D/broker.conf (HOST/PORT/AUTH/USER/PW) - 'install.sh
#      server' reads these as its broker defaults
#
# Style: same as install.sh - single entrance, single exit, functions take
# their inputs as arguments, print their value on stdout (when any), return
# 0/1, status lines (msg) go to stderr. No globals: the broker dir, the
# bind address and the mode are all passed by name. The entry function
# states its steps as numbered comments, one action each.

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

## net_address
## Prints this machine's network address - what another machine would use to
## reach it: a WireGuard/tunnel address first (the usual seedbox case), then
## the first non-loopback IPv4, and 127.0.0.1 when nothing is found.
function net_address()
{
    local _a

    _a=$(ip -4 -o addr show 2>/dev/null \
        | awk '$2 ~ /^(wg|tun)[0-9]*$/ { split($4, _p, "/"); print _p[1]; exit }')
    if [[ -n "${_a}" ]]
    then
        printf '%s' "${_a}"
        return 0
    fi

    for _a in $(hostname -I 2>/dev/null)
    do
        case "${_a}" in
            127.*|169.254.*) continue ;;
        esac
        printf '%s' "${_a}"
        return 0
    done

    printf '%s' "127.0.0.1"
}

## broker_dir
## Prints the static broker's state dir: ~/.Q4D/mosquitto (bin/, config,
## credentials, certs, logs all live there).
function broker_dir()
{
    printf '%s' "${HOME}/.Q4D/mosquitto"
}

## mosq_bin <name>
## Prints the path of a mosquitto binary: the PATH copy first (a package
## install), then the static install, then the distro location.
function mosq_bin()
{
    local _b

    _b=$(command -v "$1" 2>/dev/null)
    if [[ -z "${_b}" && -x "${HOME}/.Q4D/mosquitto/bin/$1" ]]
    then
        _b="${HOME}/.Q4D/mosquitto/bin/$1"
    fi
    if [[ -z "${_b}" ]]
    then
        _b="/usr/bin/$1"
    fi

    printf '%s' "${_b}"
}

## have_sudo
## True when this user can run the system package manager (root or sudo).
## Non-interactive first (sudo -n: fails fast on a password-protected
## sudo); a passworded sudo is asked exactly once, and only on a tty -
## on a pipe (the install one-liner) it would just hang.
function have_sudo()
{
    if [[ ${EUID} -eq 0 ]]
    then
        return 0
    fi

    if ! command -v sudo >/dev/null
    then
        return 1
    fi

    if sudo -n true 2>/dev/null
    then
        return 0
    fi

    if [[ -t 0 ]]
    then
        sudo true 2>/dev/null
        return $?
    fi

    return 1
}

## run_root <cmd...>
## Runs <cmd...> as root (directly when already root, via sudo otherwise).
function run_root()
{
    if [[ ${EUID} -eq 0 ]]
    then
        "$@"
    else
        sudo "$@"
    fi
}

## pkg_install <pkg...>
## Installs the given packages with the distro's manager (best effort - the
## package names differ per distro; the caller verifies what actually
## appeared on the PATH).
function pkg_install()
{
    local _rc=1

    if command -v apt-get >/dev/null
    then
        run_root apt-get install -y "$@" && _rc=0
    elif command -v dnf >/dev/null
    then
        run_root dnf install -y "$@" && _rc=0
    elif command -v yum >/dev/null
    then
        run_root yum install -y "$@" && _rc=0
    elif command -v pacman >/dev/null
    then
        run_root pacman -S --noconfirm "$@" && _rc=0
    elif command -v zypper >/dev/null
    then
        run_root zypper --non-interactive install "$@" && _rc=0
    elif command -v apk >/dev/null
    then
        run_root apk add "$@" && _rc=0
    else
        msg "no known package manager (apt/dnf/yum/pacman/zypper/apk)"
        return 1
    fi

    return ${_rc}
}

## --- the static install ----------------------------------------------------------

## find_tarball <requested>
## Prints the path of a usable static tarball: <requested> when it is an
## existing file; a download when it is a URL; and the pinned GitHub
## release (MOSQUITTO_STATIC_URL overrides the URL) when empty. Verifies
## the .sha256 sidecar when the server has one.
function find_tarball()
{
    local _requested=$1
    local _url="${MOSQUITTO_STATIC_URL:-https://github.com/weaselBuddha/Queue4Download/releases/download/mosquitto-static-2.0.22/mosquitto-2.0.22-static-x86_64-linux-musl.tar.xz}"
    local _local="${HOME}/.Q4D/mosquitto-static.tar.xz"
    local _sha=""
    local _rc=1

    if [[ -n "${_requested}" && -f "${_requested}" ]]
    then
        printf '%s' "${_requested}"
        return 0
    fi
    if [[ -n "${_requested}" ]]
    then
        _url="${_requested}"
    elif [[ -f "${_local}" && -z "${MOSQUITTO_STATIC_URL:-}" ]]
    then
        # A cached download of the pinned release is fine when nothing
        # else is asked for.
        printf '%s' "${_local}"
        return 0
    fi

    msg "static tarball: ${_url}"
    mkdir -p "${HOME}/.Q4D"
    if curl -fsSL -o "${_local}" "${_url}" 2>/dev/null
    then
        _rc=0
    elif command -v wget >/dev/null && wget -q -O "${_local}" "${_url}"
    then
        _rc=0
    else
        msg "download failed (build the release via the mosquitto-static workflow, or pass --tarball=PATH)"
        return 1
    fi

    # Best-effort integrity check: the release carries a .sha256 sidecar.
    _sha=$(curl -fsSL --max-time 10 "${_url}.sha256" 2>/dev/null | awk '{print $1}')
    if [[ -n "${_sha}" ]]
    then
        if [[ "$(sha256sum "${_local}" 2>/dev/null | awk '{print $1}')" != "${_sha}" ]]
        then
            msg "sha256 mismatch - refusing the tarball"
            _rc=1
        else
            msg "sha256 ok"
        fi
    else
        msg "no .sha256 sidecar available - continuing unchecked"
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        printf '%s' "${_local}"
    fi

    return ${_rc}
}

## install_static <tarball>
## Extracts the static tarball into ~/.Q4D/mosquitto (bin/ + VERSION).
function install_static()
{
    local _tarball=$1
    local _dir
    local _tmp
    local _pkgdir
    local _rc=1

    _dir=$(broker_dir)
    _tmp=$(mktemp -d)

    if tar xJf "${_tarball}" -C "${_tmp}" 2>/dev/null
    then
        # The tarball is one top-level dir holding bin/
        _pkgdir=$(find "${_tmp}" -maxdepth 1 -type d ! -path "${_tmp}" | head -n1)
        if [[ -n "${_pkgdir}" && -x "${_pkgdir}/bin/mosquitto" ]]
        then
            mkdir -p "${_dir}/bin"
            cp -f "${_pkgdir}/bin/"mosquitto* "${_dir}/bin/"
            [[ -f "${_pkgdir}/VERSION" ]] && cp -f "${_pkgdir}/VERSION" "${_dir}/"
            chmod 755 "${_dir}/bin/"mosquitto* 2>/dev/null
            _rc=0
        fi
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        msg "static mosquitto $(cat "${_dir}/VERSION" 2>/dev/null) installed: ${_dir}/bin"
    else
        msg "the tarball has no usable bin/mosquitto"
    fi

    rm -rf "${_tmp}"

    return ${_rc}
}

## install_tools_static <tarball>
## Copies only the client tools (pub/sub/passwd - NEVER the broker) from the
## static tarball into ~/.Q4D/mosquitto/bin. For a machine that already runs
## a broker (package or whatever) but is missing the tools and has no sudo
## to install the clients package.
function install_tools_static()
{
    local _tarball=$1
    local _dir
    local _tmp
    local _pkgdir
    local _b
    local _rc=1

    _dir=$(broker_dir)
    _tmp=$(mktemp -d)

    if tar xJf "${_tarball}" -C "${_tmp}" 2>/dev/null
    then
        _pkgdir=$(find "${_tmp}" -maxdepth 1 -type d ! -path "${_tmp}" | head -n1)
        if [[ -n "${_pkgdir}" && -x "${_pkgdir}/bin/mosquitto_pub" ]]
        then
            mkdir -p "${_dir}/bin"
            for _b in mosquitto_pub mosquitto_sub mosquitto_passwd
            do
                [[ -x "${_pkgdir}/bin/${_b}" ]] && cp -f "${_pkgdir}/bin/${_b}" "${_dir}/bin/"
            done
            chmod 755 "${_dir}/bin/"mosquitto_pub "${_dir}/bin/"mosquitto_sub "${_dir}/bin/"mosquitto_passwd 2>/dev/null
            msg "client tools from the static tarball: ${_dir}/bin (the existing broker is left untouched)"
            _rc=0
        fi
    fi

    rm -rf "${_tmp}"

    return ${_rc}
}

## path_hint <dir>
## Makes shells find the static binaries: adds <dir> to the PATH in
## ~/.profile and ~/.bashrc (guarded, idempotent). The Q4D scripts do not
## need this (Q4Ddefines.sh knows the static location) - it is for humans.
function path_hint()
{
    local _f
    local _line="# Q4D mosquitto (static install)"

    for _f in "${HOME}/.profile" "${HOME}/.bashrc"
    do
        if [[ -f "${_f}" ]] && ! grep -qF "${_line}" "${_f}"
        then
            {
                echo "${_line}"
                echo "case \":\$PATH:\" in *\":${1}:\"*) ;; *) export PATH=\"${1}:\$PATH\" ;; esac"
            } >> "${_f}"
        fi
    done
}

## --- credentials -------------------------------------------------------------------

## gen_password
## Prints a random 32-hex-digit password (openssl, or /dev/urandom).
function gen_password()
{
    if command -v openssl >/dev/null
    then
        openssl rand -hex 16
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

## make_passwd <dir> <user> <password>
## (Re)creates <dir>/passwd with the one user, via mosquitto_passwd (the
## file holds the salted hash, never the password).
function make_passwd()
{
    local _dir=$1
    local _user=$2
    local _pw=$3
    local _mpw
    local _rc=1

    _mpw=$(mosq_bin mosquitto_passwd)

    if [[ -x "${_mpw}" ]]
    then
        mkdir -p "${_dir}"
        "${_mpw}" -c -b "${_dir}/passwd" "${_user}" "${_pw}" </dev/null && \
        chmod 600 "${_dir}/passwd" && _rc=0
    else
        msg "mosquitto_passwd not found - cannot create the password file"
    fi

    return ${_rc}
}

## make_tls <dir> <bind> <cn>
## Generates a self-contained PKI in <dir>/tls: a CA, the server cert
## (SAN = the bind address + hostname) and the client cert (CN = <cn>).
## The client cert stays in <dir>/tls - the home server pulls it from there
## (install.sh client).
function make_tls()
{
    local _dir=$1
    local _bind=$2
    local _cn=$3
    local _t
    local _san
    local _rc=0

    if ! command -v openssl >/dev/null
    then
        msg "openssl not found - the TLS mode needs it (re-run with the username mode)"
        return 1
    fi

    _t="${_dir}/tls"
    mkdir -p "${_t}"
    chmod 700 "${_t}"

    _san="DNS:$(hostname 2>/dev/null || echo seedbox)"
    case "${_bind}" in
        *.*) _san="${_san},IP:${_bind}" ;;
    esac

    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "${_t}/ca.key" -out "${_t}/ca.crt" -subj "/CN=Q4D Broker CA" 2>/dev/null || _rc=1
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "${_t}/server.key" -out "${_t}/server.csr" -subj "/CN=$(hostname 2>/dev/null || echo seedbox)" 2>/dev/null || _rc=1
    openssl x509 -req -in "${_t}/server.csr" -CA "${_t}/ca.crt" -CAkey "${_t}/ca.key" \
        -CAcreateserial -out "${_t}/server.crt" -days 3650 \
        -extfile <(printf "subjectAltName=%s" "${_san}") 2>/dev/null || _rc=1
    openssl req -newkey rsa:2048 -sha256 -nodes \
        -keyout "${_t}/client.key" -out "${_t}/client.csr" -subj "/CN=${_cn}" 2>/dev/null || _rc=1
    openssl x509 -req -in "${_t}/client.csr" -CA "${_t}/ca.crt" -CAkey "${_t}/ca.key" \
        -CAcreateserial -out "${_t}/client.crt" -days 3650 2>/dev/null || _rc=1

    if [[ ${_rc} -eq 0 ]]
    then
        chmod 600 "${_t}/ca.key" "${_t}/server.key" "${_t}/client.key"
        rm -f "${_t}/server.csr" "${_t}/client.csr" "${_t}/ca.srl"
        msg "PKI generated: ${_t} (CA, server and client certs; 10 years)"
    fi

    return ${_rc}
}

## --- configuration ---------------------------------------------------------------

## write_conf <dir> <conffile> <persist> <logfile> <bind> <port> <mode>
## Writes the broker config for the chosen auth mode. <dir> holds the
## credentials (passwd, tls/); <persist>/<logfile> are empty when the
## distro's defaults apply (package installs). The broker is assumed to be
## on the seedbox, not behind a NAT: the listener binds the network address
## so the home server can reach it directly.
function write_conf()
{
    local _dir=$1
    local _conffile=$2
    local _persist=$3
    local _logfile=$4
    local _bind=$5
    local _port=$6
    local _mode=$7
    local _rc=1

    {
        echo "# Q4D mosquitto config - written by install-broker.sh on $(date)"
        echo "# auth mode: ${_mode}"
        if [[ "${_mode}" == "tls" ]]
        then
            # require_certificate is the auth gate (only certs signed by our
            # CA can connect); the CN becomes the username. allow_anonymous
            # must be set explicitly: mosquitto 2.x disallows anonymous when
            # any auth option is set and it is not, and with no password
            # file the connect check falls through to exactly that flag.
            echo "listener ${_port} ${_bind}"
            echo "cafile ${_dir}/tls/ca.crt"
            echo "certfile ${_dir}/tls/server.crt"
            echo "keyfile ${_dir}/tls/server.key"
            echo "require_certificate true"
            echo "use_identity_as_username true"
            echo "allow_anonymous true"
        else
            echo "listener ${_port} ${_bind}"
            if [[ "${_mode}" == "username" ]]
            then
                echo "allow_anonymous false"
                echo "password_file ${_dir}/passwd"
            fi
        fi
        if [[ -n "${_persist}" ]]
        then
            echo "persistence true"
            echo "persistence_location ${_persist}"
        fi
        if [[ -n "${_logfile}" ]]
        then
            echo "log_dest file ${_logfile}"
        fi
        echo "log_dest stdout"
    } > "${_conffile}" && _rc=0

    return ${_rc}
}

## write_client_conf <mode> <user> <password> <clicertdir>
## Writes the mosquitto_pub/sub client config files (600) - the ones
## Q4Dlib.sh's bus_auth looks for, so the credentials never appear on a
## command line. NOTE: those files hold CLI option tokens (-u/-P,
## --cafile/...), not "key value" pairs. The TLS paths point at
## <clicertdir>/tls (kept user-readable, even in package mode).
function write_client_conf()
{
    local _mode=$1
    local _user=$2
    local _pw=$3
    local _clicertdir=$4
    local _cfg
    local _f
    local _rc=1

    _cfg="${XDG_CONFIG_HOME:-${HOME}/.config}"

    mkdir -p "${_cfg}"
    for _f in "${_cfg}/mosquitto_pub" "${_cfg}/mosquitto_sub"
    do
        if [[ "${_mode}" == "tls" ]]
        then
            printf -- '--cafile %s\n--cert %s\n--key %s\n' \
                "${_clicertdir}/tls/ca.crt" "${_clicertdir}/tls/client.crt" "${_clicertdir}/tls/client.key" > "${_f}"
        elif [[ "${_mode}" == "username" ]]
        then
            printf -- '-u %s\n-P %s\n' "${_user}" "${_pw}" > "${_f}"
        else
            : > "${_f}"
        fi
        chmod 600 "${_f}" || break
    done && _rc=0

    if [[ ${_rc} -eq 0 ]]
    then
        msg "client config files: ${_cfg}/mosquitto_pub, ${_cfg}/mosquitto_sub (mode: ${_mode})"
    fi

    return ${_rc}
}

## write_broker_conf <bind> <port> <mode> <user> <password>
## Writes ~/.Q4D/broker.conf - 'install.sh server' reads these as its
## broker defaults (broker_conf <key>).
function write_broker_conf()
{
    local _bind=$1
    local _port=$2
    local _mode=$3
    local _user=$4
    local _pw=$5
    local _f="${HOME}/.Q4D/broker.conf"
    local _rc=1

    mkdir -p "${HOME}/.Q4D" && \
    {
        echo "HOST=${_bind}"
        echo "PORT=${_port}"
        echo "AUTH=${_mode}"
        if [[ "${_mode}" == "username" ]]
        then
            echo "USER=${_user}"
            echo "PW=${_pw}"
        fi
    } > "${_f}" && chmod 600 "${_f}" && _rc=0

    return ${_rc}
}

## --- daemon ------------------------------------------------------------------------

## daemon_systemd_user <dir>
## Runs the static broker as a systemd user unit (no root needed, but a
## systemd user session must be available).
function daemon_systemd_user()
{
    local _dir=$1
    local _unit="${HOME}/.config/systemd/user/q4d-mosquitto.service"
    local _rc=1

    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || ! systemctl --user daemon-reload 2>/dev/null
    then
        return 1
    fi

    mkdir -p "${HOME}/.config/systemd/user" && \
    cat > "${_unit}" <<EOF
[Unit]
# Q4D mosquitto broker (static install, no root needed)
Description=Q4D mosquitto broker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${_dir}/bin/mosquitto -c ${_dir}/mosquitto.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null && \
    systemctl --user enable --now q4d-mosquitto.service 2>/dev/null && _rc=0

    return ${_rc}
}

## daemon_cron <dir>
## Runs the static broker via cron: an @reboot start plus a per-minute
## keepalive, guarded by flock (a double start is then harmless).
function daemon_cron()
{
    local _dir=$1
    local _flock
    local _cmd
    local _crontab
    local _rc=1

    _flock=$(command -v flock 2>/dev/null)
    if [[ -z "${_flock}" ]]
    then
        msg "flock not found - cannot set up the cron keepalive"
        return 1
    fi

    _cmd="${_flock} -xn ${_dir}/mosquitto.lck -c '${_dir}/bin/mosquitto -c ${_dir}/mosquitto.conf' >> ${_dir}/broker.log 2>&1"

    _crontab=$(crontab -l 2>/dev/null | grep -vF "# Q4D mosquitto")
    {
        [[ -n "${_crontab}" ]] && printf '%s\n' "${_crontab}"
        echo "@reboot ${_cmd} # Q4D mosquitto"
        echo "* * * * * ${_cmd} || true # Q4D mosquitto"
    } | crontab - && _rc=0

    return ${_rc}
}

## start_daemon <dir> <static|package>
## Starts the broker and keeps it running: the distro service for a
## package install (root/sudo), a systemd user unit or cron for the static
## install. Prints the method used (package|user|cron).
function start_daemon()
{
    local _dir=$1
    local _how=$2
    local _rc=1

    if [[ ${_how} == package ]]
    then
        run_root systemctl daemon-reload 2>/dev/null
        run_root systemctl enable --now mosquitto.service 2>/dev/null && _rc=0
    elif daemon_systemd_user "${_dir}"
    then
        _how=user
        _rc=0
    elif daemon_cron "${_dir}"
    then
        _how=cron
        _rc=0
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        printf '%s' "${_how}"
    fi

    return ${_rc}
}

## verify_broker <bind> <port> <tries>
## Publishes one message through the broker using the client config files
## (no credentials on the command line). A CONNACK + PUBACK proves the
## broker is up and the auth is right. Best effort: reports, never fails.
function verify_broker()
{
    local _bind=$1
    local _port=$2
    local _tries=$3
    local _mpub
    local _i
    local _rc=1

    _mpub=$(mosq_bin mosquitto_pub)

    if [[ ! -x "${_mpub}" ]]
    then
        msg "verify: mosquitto_pub not found - skipping"
        return 0
    fi

    for _i in $(seq 1 "${_tries}")
    do
        if timeout 10 "${_mpub}" -h "${_bind}" -p "${_port}" -t "Q4D/broker/check" -m ok -q 1 </dev/null 2>/dev/null
        then
            _rc=0
            break
        fi
        sleep 2
    done

    if [[ ${_rc} -eq 0 ]]
    then
        msg "broker: ok (${_bind}:${_port}, config-file auth accepted)"
    else
        msg "broker: NOT reachable (${_bind}:${_port}) - check the daemon and the firewall (continuing)"
    fi

    return 0
}

## --- package-mode plumbing (root/sudo) ------------------------------------------------

## pkg_state_dir
## Prints the package mode's credential dir: /etc/mosquitto/q4d (dedicated,
## so an existing /etc/mosquitto/passwd or the distro's config are never
## clobbered - only mosquitto.conf itself is replaced, with a backup).
function pkg_state_dir()
{
    printf '%s' "/etc/mosquitto/q4d"
}

## pkg_install_creds <srcdir>
## Copies the credentials generated in <srcdir> (passwd, tls/) into the
## package state dir and hands them to the mosquitto user. The CLIENT cert
## stays in <srcdir>/tls (the home server must pull it, and the invoking
## user must keep reading it).
function pkg_install_creds()
{
    local _src=$1
    local _dst
    local _muser
    local _rc=1

    _dst=$(pkg_state_dir)
    _muser=$(getent passwd mosquitto 2>/dev/null | cut -d: -f1)

    if [[ ${EUID} -eq 0 ]]
    then
        mkdir -p "${_dst}"
        [[ -f "${_src}/passwd" ]] && cp -f "${_src}/passwd" "${_dst}/passwd"
        [[ -d "${_src}/tls" ]] && cp -rf "${_src}/tls" "${_dst}/tls"
        [[ -n "${_muser}" ]] && chown -R "${_muser}:" "${_dst}" 2>/dev/null
        chmod 700 "${_dst}"
        [[ -f "${_dst}/passwd" ]] && chmod 640 "${_dst}/passwd"
        _rc=0
    elif run_root mkdir -p "${_dst}" \
        && { [[ -f "${_src}/passwd" ]] && run_root cp -f "${_src}/passwd" "${_dst}/passwd"; } \
        && { [[ -d "${_src}/tls" ]] && run_root cp -rf "${_src}/tls" "${_dst}/tls"; } \
        && { [[ -n "${_muser}" ]] && run_root chown -R "${_muser}:" "${_dst}"; } \
        && run_root chmod 700 "${_dst}"
    then
        [[ -f "${_dst}/passwd" ]] && run_root chmod 640 "${_dst}/passwd"
        _rc=0
    fi

    return ${_rc}
}

## pkg_write_conf <dir> <bind> <port> <mode>
## Backs up the distro's mosquitto.conf and writes the Q4D one (the
## credentials live in the package state dir).
function pkg_write_conf()
{
    local _dir=$1
    local _bind=$2
    local _port=$3
    local _mode=$4
    local _conf="/etc/mosquitto/mosquitto.conf"
    local _tmpconf
    local _rc=1

    _tmpconf=$(mktemp)
    if write_conf "${_dir}" "${_tmpconf}" "" "" "${_bind}" "${_port}" "${_mode}"
    then
        if [[ ${EUID} -eq 0 ]]
        then
            [[ -f "${_conf}" ]] && cp -f "${_conf}" "${_conf}.orig-$(date +%s)"
            cp -f "${_tmpconf}" "${_conf}" && chmod 644 "${_conf}" && _rc=0
        else
            run_root bash -c "[[ -f ${_conf} ]] && cp -f ${_conf} ${_conf}.orig-$(date +%s)" 2>/dev/null
            run_root cp -f "${_tmpconf}" "${_conf}" && run_root chmod 644 "${_conf}" && _rc=0
        fi
    fi

    rm -f "${_tmpconf}"

    return ${_rc}
}

## --- entry point ---------------------------------------------------------------------

## install_broker [--tarball=PATH-OR-URL]
## Lays out the broker on the seedbox.
function install_broker()
{
    local _tarball_req=""
    local _tarball=""
    local _dir
    local _pdir=""
    local _bind=""
    local _port=""
    local _mode=""
    local _user=""
    local _pw=""
    local _existing=0
    local _static=0
    local _daemonhow=""
    local _t=""
    local _rc=0

    _dir=$(broker_dir)

    echo "Broker install on $(hostname) -> ${_dir}"
    echo

    # 1. Is mosquitto already there? When it is, nothing is installed.
    if command -v mosquitto >/dev/null
    then
        _existing=1
        msg "mosquitto already present ($(command -v mosquitto)) - nothing will be installed"
        if ! command -v mosquitto_pub >/dev/null && have_sudo
        then
            msg "clients missing - installing the clients package"
            pkg_install mosquitto-clients || pkg_install mosquitto || true
        fi
    fi

    # 2a. A pre-existing broker with missing tools and no sudo: the broker
    #     stays, the client tools come from the static tarball.
    if [[ ${_rc} -eq 0 && ${_existing} -eq 1 ]] && ! have_sudo
    then
        for _t in mosquitto_pub mosquitto_sub mosquitto_passwd
        do
            if ! command -v "${_t}" >/dev/null && [[ ! -x "${_dir}/bin/${_t}" ]]
            then
                msg "client tools missing (no sudo) - taking them from the static tarball"
                _tarball_req=$(require_opt tarball "$@") || _rc=1
                if [[ ${_rc} -eq 0 ]]
                then
                    _tarball=$(find_tarball "${_tarball_req}") || _rc=1
                fi
                if [[ ${_rc} -eq 0 ]]
                then
                    install_tools_static "${_tarball}" || _rc=1
                    path_hint "${_dir}/bin"
                fi
                break
            fi
        done
    fi

    # 2b. No broker at all: install it (package when sudo allows, else
    #     the full static tarball).
    if [[ ${_rc} -eq 0 && ${_existing} -eq 0 ]]
    then
        if have_sudo
        then
            msg "installing the distro package (mosquitto + clients)"
            if ! pkg_install mosquitto mosquitto-clients
            then
                msg "the 'mosquitto mosquitto-clients' pair failed - trying 'mosquitto' alone"
                pkg_install mosquitto || true
            fi
            if ! command -v mosquitto_pub >/dev/null
            then
                pkg_install mosquitto-clients || true
            fi
        fi
        if ! command -v mosquitto >/dev/null
        then
            _static=1
            msg "no package available (no sudo, or no package) - using the static build"
            _tarball_req=$(require_opt tarball "$@") || _rc=1
        fi
    fi
    if [[ ${_rc} -eq 0 && ${_existing} -eq 0 && ${_static} -eq 1 ]]
    then
        _tarball=$(find_tarball "${_tarball_req}") || _rc=1
        if [[ ${_rc} -eq 0 ]]
        then
            install_static "${_tarball}" || _rc=1
            path_hint "${_dir}/bin"
        fi
    fi
    if [[ ${_rc} -eq 0 ]] && ! command -v mosquitto >/dev/null \
        && [[ ! -x "${_dir}/bin/mosquitto" ]]
    then
        msg "ERROR: no mosquitto broker available (package and static install both failed)"
        _rc=1
    fi

    # 3. Bind address and port (the seedbox is not behind a NAT: the home
    #    server connects to this address directly). The port default is
    #    picked with the auth mode, so ask the address first.
    if [[ ${_rc} -eq 0 ]]
    then
        _bind=$(prompt "broker bind address (the seedbox address the home server uses; 0.0.0.0 = all)" "$(net_address)")
    fi

    # 4. Credentials (username/password, TLS client certs, or none).
    if [[ ${_rc} -eq 0 ]]
    then
        _mode=$(prompt "auth mode (username | tls | none)" "username")
        case "${_mode}" in
            tls)
                _port=$(prompt "broker port (TLS)" "8883")
                _user=$(prompt "certificate common name (client identity)" "mosquitto_user")
                make_tls "${_dir}" "${_bind}" "${_user}" || _rc=1
                ;;
            none)
                _port=$(prompt "broker port" "1883")
                msg "WARNING: no auth on a broker that is not behind a NAT - anyone who can reach ${_bind}:${_port} can publish/subscribe"
                ;;
            *)
                _mode=username
                _port=$(prompt "broker port" "1883")
                _user=$(prompt "MQTT username" "mosquitto_user")
                _pw=$(prompt "MQTT password (empty = generate)" "")
                if [[ -z "${_pw}" ]]
                then
                    _pw=$(gen_password)
                    msg "generated password: ${_pw}"
                fi
                make_passwd "${_dir}" "${_user}" "${_pw}" || _rc=1
                ;;
        esac
    fi

    # 5. The broker config for the chosen mode.
    if [[ ${_rc} -eq 0 && ${_static} -eq 1 ]]
    then
        mkdir -p "${_dir}/persist"
        write_conf "${_dir}" "${_dir}/mosquitto.conf" "${_dir}/persist" "${_dir}/broker.log" \
            "${_bind}" "${_port}" "${_mode}" || _rc=1
    fi
    if [[ ${_rc} -eq 0 && ${_static} -eq 0 ]] && have_sudo
    then
        # A package broker (fresh or pre-existing): credentials to
        # /etc/mosquitto/q4d, config to /etc/mosquitto (backed up).
        _pdir=$(pkg_state_dir)
        pkg_install_creds "${_dir}" || _rc=1
        if [[ ${_rc} -eq 0 ]]
        then
            pkg_write_conf "${_pdir}" "${_bind}" "${_port}" "${_mode}" || _rc=1
        fi
    fi
    if [[ ${_rc} -eq 0 && ${_static} -eq 0 ]] && ! have_sudo
    then
        # A pre-existing package broker without sudo: we cannot write
        # /etc/mosquitto - configure the client side only, print the rest.
        msg "no sudo - the existing package broker cannot be reconfigured here (steps 5/7 skipped)"
    fi

    # 6. The client config files (credentials off the command line).
    if [[ ${_rc} -eq 0 ]]
    then
        write_client_conf "${_mode}" "${_user}" "${_pw}" "${_dir}" || _rc=1
    fi

    # 7. Run the daemon (best effort - a failure prints manual steps).
    #    Skipped for a pre-existing package broker without sudo (step 5
    #    already said so).
    if [[ ${_rc} -eq 0 ]] && ! { [[ ${_static} -eq 0 ]] && ! have_sudo; }
    then
        if [[ ${_static} -eq 1 ]]
        then
            _daemonhow=$(start_daemon "${_dir}" static) || _rc=1
        else
            _daemonhow=$(start_daemon "${_dir}" package) || _rc=1
        fi
        if [[ ${_rc} -eq 0 ]]
        then
            msg "daemon: running (${_daemonhow})"
        else
            msg "daemon: could not be installed automatically - start it manually:"
            if [[ ${_static} -eq 1 ]]
            then
                msg "  ${_dir}/bin/mosquitto -c ${_dir}/mosquitto.conf"
            else
                msg "  sudo systemctl restart mosquitto"
            fi
        fi
    fi

    # 8. Verify + record the coordinates for 'install.sh server'.
    if [[ ${_rc} -eq 0 ]]
    then
        verify_broker "${_bind}" "${_port}" 3
        write_broker_conf "${_bind}" "${_port}" "${_mode}" "${_user}" "${_pw}" || _rc=1
    fi

    if [[ ${_rc} -eq 0 ]]
    then
        echo
        echo "Broker installed: ${_bind}:${_port} (auth: ${_mode})"
        echo
        echo "Next, on this seedbox, run:"
        echo "  install.sh server"
        echo "It reads ~/.Q4D/broker.conf for the broker defaults."
    fi

    return ${_rc}
}

install_broker "$@"
