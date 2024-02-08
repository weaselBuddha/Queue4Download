#!/usr/bin/python3

import os
import sys
# Dependency:  pip install deluge-client
from deluge_client import LocalDelugeRPCClient

torrent = sys.argv[1]
label = sys.argv[2]

print("Setting label of %s to \"%s\"" %(torrent,label))

client = LocalDelugeRPCClient()

client.connect()

if client.connected:

    try:
        client.label.add(label)
    except:
        pass

    try:
        client.label.set_torrent(torrent, label)
    except:
        print ("Failed to Set Label")
else:
    print ("Failed to Connect, Deluged Running?")
