# Q4Dv2

Refactored Queue4Download: same architecture (MQTT event bus + LFTP transfer),
reorganized by deployment role, with the v1 bug fixes applied.

## Layout

    Q4Dv2/
    ├── install.sh                 server | client subcommands
    ├── common/                    installed flat into ~/.Q4D/ on BOTH machines
    │   ├── Q4Dconfig.sh           bus coords, credentials, LABELLING, LOG_MODE,
    │                              per-machine log files, Q4D_ROLE
    │   ├── Q4Ddefines.sh          publisher/subscriber, channels, labels, event protocol
    │   ├── Q4Dlib.sh              PublishEvent, GetEvent, log, log_pub, WaitLock, make_label_event
    │   └── LogD.sh                central log daemon (bus mode: subscribes
    │                              "Logs" -> flat file; client, server, or both)
    ├── server/                    installed into ~/.Q4D/ on the SEEDBOX
    │   ├── Q4Dserver.sh           log file, Types.config path, default type
    │   ├── Queue4Download.sh      torrent completion hook (orchestrator)
    │   ├── LabelD.sh              label daemon (subscribes "Label", calls SetLabel)
    │   ├── Types.config           type code rules
    │   ├── torrenttools/          one plugin per torrent client (GetPayloadDetails + SetLabel)
    │   └── labellers/             delugeLabeller.py, qbitLabeller.py
    └── client/                    installed into ~/.Q4D/ on the HOME server
        ├── Q4Dclient.sh           LFTP settings + TypeCodes map
        ├── ProcessEvent.sh        queue daemon (subscribes "Down", forks LFTPtransfer)
        ├── LFTPtransfer.sh        transfer engine + ACK/NACK
        ├── processEvent.service
        └── logDaemon.service

## What changed from Q4D/ (v1)

Structure
- Role split: `common/` (both machines), `server/` (seedbox), `client/` (home)
  instead of one flat directory.
- `Q4Dlib.sh`: shared `PublishEvent` / `GetEvent` / `WaitLock` / `log` /
  `make_label_event` (v1 duplicated these across scripts).
- Torrent client support is now a plugin: `server/torrenttools/TorrentTool.<name>`.
  `install.sh server` copies the selected one to `~/.Q4D/TorrentTool.sh`; the
  hook and LabelD source it and call `GetPayloadDetails` / `SetLabel`. Each tool
  file documents its own hook line.
- Labellers in `server/labellers/`, referenced by their tools.
- Event protocol (channels, payload shapes, field indexes, who talks to whom)
  documented in one place: `common/Q4Ddefines.sh`.
- `install.sh`: `server` lays out the seedbox and selects the tool; `client`
  pulls files over ssh, verifies the broker with real credentials, builds the
  TypeCodes map from the server's Types.config, and installs the systemd
  units (processEvent + logDaemon).

Bug fixes (from the v1 review)
- B1  aria2 removed as tool
- B2  `$Q_FAILED` typo (empty label on failure) -> `$Q_FAIL`, defined once
- B3  MarkQueued `[[ ${_sent} ]]` was always true -> `[[ ${_sent} == 0 ]]`
- B4  LFTPtransfer `[[ $LABELLING && ... ]]` was always true ("false" is
      non-empty) -> shared `labelling_enabled()` predicate
- B5  PublishEvent always returned 0 (trailing `echo $?`) -> real exit status
- B6  ProcessEvent `exec 2>&1 >>log` lost stderr -> `exec >>log 2>&1`
- B7  SetType tier check (single-word `[[ ${_type}==$assigned ]]`) degraded to
      a unary test -> quoted, spaced comparison
- B8  SetType CONTAINS regex (unescaped value, stray trailing quantifier)
      -> glob match
- B9  daemons died on any broker blip -> retry loop with 5s backoff
- B10 `/tmp/lock`, `/tmp/scratchCodes`, `/tmp/fail$$.log` ->
      `$Q4D_PATH/.hook.lock`, `$Q4D_PATH/.transfer.lock`, mktemp, fail-log cleanup
- B11 rtorrent tracker `cut -d: -f4` dropped the port -> `-f4-`
- B12 unquoted `echo $1` -> `echo "$1"`
- Types.config sample: unquoted values, empty 5th column for tier 1 (the old
  sample's `""` fields never matched the parser)

## Refactor pass

Same architecture, tighter structure. Rules applied:

- Single entrance, single exit: every function has one return; the daemons'
  retry loops are the only infinite loops. Script entry points are the last
  two lines of each file (`check_tool || exit 1` / `Main ...`).
- One function per job: `install.sh` is now small functions (`require_opt`,
  `prompt`, `find_seedbox_repo`, `copy_client_files`, `check_broker`,
  `collect_type_codes`, `default_dir_for`, `build_type_code_map`,
  `generate_client_config`, `sync_labelling`, `install_systemd_unit`);
  `LFTPtransfer.sh` splits into `run_lftp` / `TransferPayload` /
  `ProcessResult`; the hook's Types.config matching splits into
  `rule_matches` (one comparator per line).
- Globals wrapped in interfaces: the hook's payload record is private
  (`_payload`) and is only touched through `payload_set` / `payload_get`,
  which validate the field name (`KEY HASH LABEL TRACKER PATH TYPE`) - a
  typo in a tool or in Types.config can no longer silently create a new key
  (the whole bug class of v1's B1). The old `Event` array in Q4Dlib is gone:
  `GetEvent` prints the payload and the daemons split it into locals.
  The only remaining globals are the readonly config files.
- Clear interfaces: `PublishEvent <channel> <event>` returns the
  publisher's status and prints nothing (it no longer echoes the rc);
  `GetEvent <channel>` prints the payload; `prompt` prints the answer
  (capture it) instead of writing the `REPLY` global; `WaitLock` requires
  its lockfile; labellers take `<torrent-hash> <label>` and print usage on
  anything else.
- Stray state localized: the hook's `numArgs` / `Invoke` and
  LFTPtransfer's `base` / `_label` / `_pub` are now function locals or
  explicit arguments; the failure log is created once in `Main` and passed
  by name (v2 re-derived it from `$$` in two places).
- ProcessEvent pre-flight: before subscribing it runs `verify_environment`
  - binaries on the PATH (`mosquitto_pub`, `mosquitto_sub`, `lftp`), a live
  broker probe, a TCP probe to the seedbox's SFTP port, and TypeCodes
  destinations (missing directories are created). Each failing check logs
  locally and to the central log; the daemon continues, because the retry
  loop heals transient failures.

Deliberate behaviour changes (all small, all arguably v1/v2 bugs):
- A missing destination directory now publishes NOPE (before the torrent
  was left stuck at QUEUED).
- `install.sh client` installs the systemd units from the scp'd copies in
  `~/.Q4D/` (the `$REPO_ROOT` copies do not exist in the pipe one-liner).
- An unknown comparator in Types.config now logs a WARN (was silent).

## Logging (either/or: flat file or bus events)

One switch in Q4Dconfig.sh (`LOG_MODE`) picks the sink for the whole
system - the file is shared, so the client gets it with the copied config.
The server install asks for it once.

- `LOG_MODE=flat` (default) - `log <LEVEL> <msg>` appends
  `<timestamp> [LEVEL] message` to the machine's own flat file - one path
  per machine, picked by `Q4D_ROLE`: `SERVER_LOG` on the seedbox (default
  `~/.Q4D/queue.log`), `CLIENT_LOG` at home (default
  `~/.Q4D/process.log`). The installer asks for the path when flat mode is
  selected. Works without a broker; no bus traffic, LogD.sh not needed.
- `LOG_MODE=bus` - `log` publishes one event per message on the `Logs`
  channel, formatted `<timestamp> | <SEVERITY> | <message>`. `LogD.sh`
  (common/, installed on both machines) subscribes to `Logs` and appends
  to `~/.Q4D/q4d_central.log`. Run it on the home server, on the seedbox,
  or on both (one central file per machine); the client installer sets up
  `logDaemon.service` automatically.
- Scripts only ever call `log` - exactly one sink per event, never both
  (the old dual-write is gone). `log_pub <SEVERITY> <msg>` is the bus-side
  sink that `log` dispatches to in bus mode.
- Exception, by design: when a transfer fails, the captured lftp output is
  copied to the active sink line by line (`publish_capture` in
  LFTPtransfer.sh), the failure headline first.
- Stray stdout/stderr still falls into the machine's local flat file (the
  daemons' `exec` redirects) - the safety net for unstructured output,
  kept in bus mode too.
- `install.sh` is a one-off: it prints to the terminal (msg/fail) and does
  not use the Q4D log.

## Quick start

    # seedbox
    git clone https://github.com/weaselBuddha/Queue4Download
    ~/Queue4Download/Q4Dv2/install.sh server --client=rtcontrol

    # home server
    ssh you@seedbox 'cat ~/Queue4Download/Q4Dv2/install.sh' | bash -s client you@seedbox

In pipe mode the prompts read the pipe's stdin, so every question takes its
default; to answer them interactively, copy install.sh over and run it from
disk.

The installed runtime layout is flat (`~/.Q4D/`), the same shape v1 users
already have, so existing installs can adopt v2 file-for-file.

The server install asks for the logging mode (`LOG_MODE` in Q4Dconfig.sh):
flat file per machine, or bus events to a central log - either/or, see
Logging below.

## Docker

Community-owned packaging (the doc "Dockerized Q4D Client.md" was removed
from the repo root - see git history). The container
simply lays out `common/` + `client/` into `$HOME/.Q4D/` and runs
ProcessEvent.sh; the seedbox side stays plain scripts.
