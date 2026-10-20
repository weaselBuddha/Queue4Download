# Q4Dv2 installation

Three things are installed, in this order — all of them start on the
seedbox, the client install is pulled from there:

    seedbox                          home server
    +----------------------------+   +----------------------------+
    | 1. mosquitto broker        |   | 3. Q4D client             |
    |    (install-broker.sh)     |   |    (install.sh client)    |
    | 2. Q4D server              |   |  ProcessEvent daemon,     |
    |    (install.sh server)     |   |  LFTP transfers, LogD     |
    |  Queue4Download hook,      |   +-----------^--------------+
    |  LabelD daemon, tools      |               |
    +--------------^-------------+               |
                   |            SFTP/SSH (q4d key)|
                   +---------  MQTT bus (TLS     |
                              client-cert auth) --+
                              port 8883, 8883

- **Broker** (seedbox): the MQTT bus. TLS client-cert auth — the
  certificate IS the credential, there is no password.
- **Server** (seedbox): the torrent-side logic. A hook in the torrent
  client fires `Queue4Download.sh` on completion; the server types the
  payload, publishes a "Down" event, and applies labels ("Label"
  channel) through the torrent tool.
- **Client** (home server): subscribes to "Down", transfers each file
  from the seedbox over LFTP into a per-type destination directory, and
  publishes the label back.

The seedbox is assumed **not to be behind a NAT** (WireGuard/tunnel
address preferred): the home server reaches the broker and SFTP
directly, so the listener binds the seedbox's network address, never
127.0.0.1.

---

## 0. Prerequisites

**Seedbox**

| Need | Why |
|---|---|
| git | repo checkout |
| the torrent client you run (one of the adapters below) | each `install.sh server --client=<tool>` adapter talks to one of these |
| mosquitto OR nothing | with sudo the distro package is used; without it, the static tarball from the `mosquitto-static-2.0.22` GitHub release (the seedbox must be able to reach github.com) |
| openssl | generates the broker PKI (CA + server + client certs) |
| python 3 (or 2) + pip, when needed by the tool | `rtcontrol` selected but missing: the installer runs `pip --user install pyrosimple` (py3) or `pyrocore` (py2); deluge/qbit labelling: `pip install deluge-client` / `qbittorrent-api` |
| systemd (preferred) or cron + flock | runs the broker (no-systemd path: cron `@reboot` only — no keepalive) and the daemons |
| network | home server must reach the broker port (8883) and SFTP (22) |

**Torrent client adapters** (the `--client=` choice in
`install.sh server`, one per `TorrentTool.*` file):

| Tool | Client | Extra needs | Labelling |
|---|---|---|---|
| `rtcontrol` (default) | rTorrent with pyrosocket | `rtcontrol` on the PATH (installed by the installer when missing) | `rtcontrol --custom 1=<label>` |
| `rtorrent` | rTorrent, bare (no pyroscope) | none | none available |
| `deluge` | Deluge local daemon + Execute plugin | `pip install deluge-client` (labelling) | `labellers/delugeLabeller.py` |
| `qbit` | qBittorrent | `pip install qbittorrent-api` (labelling) | `labellers/qbitLabeller.py` |
| `transmission` | Transmission daemon (*untested*) | none | none by default |
| `other` | anything you wire up yourself | the hook must supply all five details | none by default |

**Home server**

| Need | Why |
|---|---|
| bash, ssh/ssh-keygen, lftp | transport to the seedbox and file transfers |
| mosquitto client tools (`mosquitto_pub`/`mosquitto_sub`) | distro `mosquitto-clients` package, or the static tarball's `bin/` placed in `~/.Q4D/mosquitto` (that fallback path is part of the lookup order) |
| systemd (preferred) or cron | runs the ProcessEvent (and LogD) daemons |

---

## 1. Clone the repo (seedbox)

    git clone https://github.com/weaselBuddha/Queue4Download

Everything below runs from `~/Queue4Download/Q4Dv2/` on the seedbox.

## 2. Broker (seedbox) — `install-broker.sh`

    ~/Queue4Download/Q4Dv2/install-broker.sh
    # optional: local path or URL for the static tarball
    ~/Queue4Download/Q4Dv2/install-broker.sh --tarball=/path/to/mosquitto-2.0.22-static-x86_64-linux-musl.tar.xz

What it does, step by step:

1. **Detects an existing mosquitto** — if one is present, nothing is
   installed (a package broker is reconfigured later; missing client
   tools are still taken from the static tarball when there is no
   sudo).
2. **Installs the broker**: distro package when sudo allows, otherwise
   the static tarball (pinned GitHub release; override with
   `MOSQUITTO_STATIC_URL` or `--tarball=`) into `~/.Q4D/mosquitto`.
3. **Asks the bind address** (default: the network address —
   WireGuard/tunnel first, else the first non-loopback IPv4) and the
   **port** (default 8883).
4. **Generates the PKI** (CA + server cert with the bind address in the
   SAN + client cert) under `~/.Q4D/mosquitto/tls`; asks for the
   client cert's common name (default `mosquitto_user`) — the CN
   becomes the broker username.
5. **Writes the broker config**: `~/.Q4D/mosquitto/mosquitto.conf`
   (static) or `/etc/mosquitto/mosquitto.conf` with a `.orig-<ts>`
   backup and the PKI in `/etc/mosquitto/q4d` (package). Auth is
   `require_certificate true`, `use_identity_as_username true`.
6. **Writes the client config files** `~/.config/mosquitto_pub` and
   `~/.config/mosquitto_sub` (600) holding the cert paths — every
   Q4D script authenticates through these, so nothing sensitive ever
   appears on a command line.
7. **Runs the daemon**: distro service (root/sudo), a systemd **user**
   unit `q4d-mosquitto.service` (no root needed), or cron `@reboot`
   with a flock guard (no systemd). There is no cron keepalive — the
   broker is expected to stay up; on systemd boxes the unit's
   `Restart=on-failure` covers crashes.
8. **Verifies** with a publish through the broker using the config-file
   auth (best effort: `broker: ok (...)` or a warning).
9. **Writes `~/.Q4D/broker.conf`** (`HOST`/`PORT`/`AUTH=tls`) — the
   server install pre-fills its broker questions from it.

Done when it prints `Broker installed: <addr>:<port> (auth: TLS
client certs)`.

## 3. Server (seedbox) — `install.sh server`

Run on the seedbox, **after the broker is installed**:

    ~/Queue4Download/Q4Dv2/install.sh server            # prompts for the tool
    ~/Queue4Download/Q4Dv2/install.sh server --client=rtcontrol   # no prompt

1. **Selects the torrent tool** (default `rtcontrol`; also `rtorrent`,
   `deluge`, `qbit`, `transmission`, `other`).
2. **Lays out `~/.Q4D/`**: `common/` + `server/` flat
   (Q4Dconfig.sh, Q4Ddefines.sh, Q4Dlib.sh, Queue4Download.sh,
   LabelD.sh, Types.config, labellers/ ...), and copies
   `TorrentTool.<tool>` to `~/.Q4D/TorrentTool.sh`.
3. **Verifies the tool contract** (`GetPayloadDetails` + `SetLabel`);
   for `rtcontrol` it also checks the `rtcontrol` binary and installs
   it when missing (python3 → `pip --user install pyrosimple`,
   python2 → `pyrocore`; a `~/bin/rtcontrol` link when `~/.local/bin`
   is not on the PATH).
4. **Asks about labelling** (warns when the tool cannot set labels —
   the switch then makes label traffic a no-op).
5. **Asks the broker coordinates** — pre-filled from
   `~/.Q4D/broker.conf` (host = the seedbox address, port 8883) and
   written to `Q4Dconfig.sh` (`BUS_HOST`/`BUS_PORT`). Credentials are
   not asked: the cert in `~/.config/mosquitto_pub` is them.
6. **Asks the log mode** (`flat` = each machine writes its own file,
   `bus` = every log line is published to the broker's "Logs" channel
   and written to one central file by LogD).
7. **Shows the type codes** (`Types.config` + default type) and offers
   an editor.
8. **Installs the daemons** (systemd with `User=<you>`, cron fallback):
   `labelDaemon.service` when labelling is on, `logDaemon.service`
   when bus mode is chosen.
9. **Records the repo path** in `~/.Q4D/.q4d-repo` — the client
   install finds the files on the seedbox through it.

It ends with `Server installed: ~/.Q4D (torrent tool: <tool>)` and
**prints the tool's header — including that tool's hook line**. The
last manual step of the whole installation is that hook: add it to the
torrent client's config (the installer prints the one you selected;
each is also in the header of `~/.Q4D/TorrentTool.sh`).

**`rtcontrol`** (rTorrent + pyrosocket) — in `.rtorrent.rc`:

    method.set_key = event.download.finished,complete,"execute.throw.bg=~/.Q4D/Queue4Download.sh,(d.hash)"

The single argument is the torrent info **hash** (exact match, safe in
the hook string); the tool resolves name/label/tracker/path from it
via rtcontrol.

**`rtorrent`** (bare, no pyroscope) — in `.rtorrent.rc`, four
arguments (name, hash, label, path):

    method.set_key = event.download.finished,complete,"execute.throw.bg=~/.Q4D/Queue4Download.sh,(d.name),(d.hash),(d.custom1),(d.data_path)"

No labelling is available with bare rTorrent (use `rtcontrol` if you
have pyroscope).

**`deluge`** — the Execute plugin (it provides the three parameters —
hash, name, path — by default):

    ~/.Q4D/Queue4Download.sh "%H" "%N" "%P"

**`qbit`** (qBittorrent: Downloads → "Run external program on torrent
completion"), five arguments (name, hash, label, tracker, path):

    ~/.Q4D/Queue4Download.sh "%N" %I %L %T "%F"

**`transmission`** (daemon; *untested*) — in
`transmission-daemon/settings.json`; the hook passes **no arguments**,
the details arrive as `TR_*` environment variables:

    "script-torrent-done-enabled": true,
    "script-torrent-done-filename": "/home/YOU/.Q4D/Queue4Download.sh"

**`other`** (any client you wire up yourself) — the hook must supply
all five details:

    ~/.Q4D/Queue4Download.sh [NAME] [HASH] [LABEL] [TRACKER] [PATH]

Restart/reload the torrent client after adding the hook so it takes
effect.

## 4. Client (home server) — `install.sh client`

From the home server, with the seedbox reachable:

    ssh you@seedbox 'cat ~/Queue4Download/Q4Dv2/install.sh' | bash -s client you@seedbox

That one-liner pipes the script over ssh, so **every prompt takes its
default** (prompts read the pipe's stdin). To answer the questions,
copy the script first (or run the repo locally) and run it from disk:

    bash install.sh client you@seedbox
    # or with the seedbox pre-answered:
    bash install.sh client --seedbox=you@seedbox

1. **Resolves the seedbox** (`user@host`, from `--seedbox=` or a prompt).
2. **Generates the Q4D ssh key** `~/.ssh/id_ed25519_q4d` (no password)
   and installs its public key on the seedbox when needed.
3. **Verifies SFTP access** to the seedbox (lftp, key auth).
4. **Pulls the files**: finds the repo on the seedbox via
   `~/.Q4D/.q4d-repo` and copies `common/` + `client/` + the shared
   `Q4Dconfig.sh` into the local `~/.Q4D/`.
5. **Makes the config machine-local**: `Q4D_ROLE=client`, and in flat
   mode asks for this machine's log file (default `~/.Q4D/process.log`).
6. **Writes the client auth**: pulls the client cert from the seedbox
   (`ca.crt`, `client.crt`, `client.key` → `~/.Q4D/mosquitto/tls`,
   600) and writes `~/.config/mosquitto_pub`/`mosquitto_sub` with the
   cert paths. (Best effort — a failure warns, the install goes on.)
7. **Verifies the MQTT broker** (best effort — the same probe the
   daemons use; a failure only warns).
8. **Walks the server's type codes** and asks for a local destination
   directory for each (these are where transfers land).
9. **Asks the LFTP settings** (host as seen from home, user:password
   fallback for when key auth is off, parallel threads, pget segments)
   and generates `~/.Q4D/Q4Dclient.sh`.
10. **Syncs the labelling switch** with the seedbox.
11. **Installs the systemd units** `processEvent.service` and
    `logDaemon.service` (the log daemon is only needed in bus mode),
    with a cron fallback.

It ends with `Client installed: ~/.Q4D (seedbox: user@host)`.

## 5. Verify the whole chain

1. **Broker** (either machine, as the Q4D user):

       mosquitto_pub -h <seedbox> -p 8883 -t q4d/manual -m ok -q 1

   Success means TLS + client-cert auth work. A client **without** the
   cert must be refused — that is the auth gate doing its job.
2. **Daemons**: each of LogD/LabelD/ProcessEvent runs a one-shot broker
   link check before its loop and logs `broker link established
   (<host>:<port>)`; on failure it logs FAIL (naming the config file to
   check) and exits, and the service (or cron) restarts it.
3. **End to end**: let a torrent finish. Expected: a "Down" event, a
   transfer into the per-type directory on the home server, and the
   label `QUEUED` → `DONE` (or `NOPE`) applied on the seedbox. Watch
   the logs (below) if anything stalls.

**Where the logs are**

| Mode | Seedbox | Home server |
|---|---|---|
| flat | `~/.Q4D/queue.log` | `~/.Q4D/process.log` |
| bus | central `~/.Q4D/Q4Dcentral.log` (written by LogD) | same |

The broker itself logs to `~/.Q4D/mosquitto/broker.log` (static install)
or the distro journal (package).

## 6. Layout reference

    seedbox ~/.Q4D/
      Q4Dconfig.sh Q4Ddefines.sh Q4Dlib.sh        # shared (client gets copies)
      Queue4Download.sh  LabelD.sh  Types.config  # server logic
      TorrentTool.sh  labellers/  torrenttools/
      .q4d-repo                        # repo path (client install reads it)
      broker.conf                      # HOST/PORT/AUTH (install-broker.sh writes it)
      mosquitto/                       # static broker: bin/ mosquitto.conf
                                       #   persist/ broker.log tls/ (the PKI)
    seedbox ~/.config/mosquitto_pub|sub           # cert paths (600)

    home    ~/.Q4D/
      Q4Dconfig.sh Q4Ddefines.sh Q4Dlib.sh        # pulled + made machine-local
      Q4Dclient.sh  LFTPtransfer.sh  ProcessEvent.sh  logDaemon.service
      mosquitto/tls/                             # the client cert (pulled, 600)
    home    ~/.config/mosquitto_pub|sub           # cert paths (600)
    home    ~/.ssh/id_ed25519_q4d                 # the Q4D transport key

## 7. Re-running and updates

- The installers are re-runnable: the broker install detects an
  existing broker (reconfiguring it instead of double-installing), and
  the server/client layouts overwrite their own files. Re-run after a
  `git pull` to update the installed scripts (daemons pick up changes
  on their next start).
- Re-running `install-broker.sh` also rewrites the broker's cron entry
  (an old per-minute keepalive line, if any, is stripped by the
  `# Q4D mosquitto` filter).
- The static tarball release is pinned in `install-broker.sh`
  (`mosquitto-static-2.0.22`); point it elsewhere with
  `MOSQUITTO_STATIC_URL` or `--tarball=`.

## 8. Troubleshooting

| Symptom | Look at |
|---|---|
| `broker link not established` (daemon log, then exits) | broker running? port/firewall? the cert config it names (`~/.config/mosquitto_pub` / `_sub`) — all three files (`ca.crt`, `client.crt`, `client.key`) must exist and be readable |
| No events at all | the hook: is the line for **your tool** present (printed by `install.sh server` — also in the header of `~/.Q4D/TorrentTool.sh`)? for rTorrent it must use `(d.hash)` (rtcontrol) or the four `(d.name),(d.hash),(d.custom1),(d.data_path)` args (bare) |
| `rtcontrol` missing / tool contract fails | python + pip present? re-run `install.sh server` — it reinstalls the tool binary |
| Client can't SFTP | `ssh -i ~/.ssh/id_ed25519_q4d you@seedbox` — key installed? `~/.Q4D/.q4d-repo` on the seedbox? |
| Broker died and nothing restarted (no systemd) | by design: the cron path is `@reboot` only — start it with `~/.Q4D/mosquitto/bin/mosquitto -c ~/.Q4D/mosquitto/mosquitto.conf` |
| Transfer lands but label missing | `LABELLING` in sync on both sides? the tool can actually set labels (`install.sh server` warns when it can't)? |
