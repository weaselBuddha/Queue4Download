#!/usr/bin/python3

# delugeLabeller.py
#
# usage: delugeLabeller.py <torrent-hash> <label>
# Dependency: pip install deluge-client

import sys
from deluge_client import LocalDelugeRPCClient

if len(sys.argv) != 3:
    print("usage: delugeLabeller.py <torrent-hash> <label>")
    sys.exit(2)

torrent = sys.argv[1]
label = sys.argv[2]

print("Setting label of %s to \"%s\"" %(torrent,label))

client = LocalDelugeRPCClient()

client.connect()

if client.connected:

    try:
        client.label.add(label)
    except Exception:
        pass

    try:
        client.label.set_torrent(torrent, label)
    except Exception:
        print ("Failed to Set Label")
        sys.exit(1)
else:
    print ("Failed to Connect, Deluged Running?")
    sys.exit(1)
