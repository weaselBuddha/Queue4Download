#!/usr/bin/python3

# qbitLabeller.py - by /u/rj_d2 with thanks (https://www.reddit.com/r/sbtech/comments/1ams0hn/q4d_updated/l9nkq4y/)

# Edit this tool to reflect your qBittorrent settings (host, port, user, pw)

# Changes to Q4Dconfig.sh

#LABELLING=true
#readonly _LABEL_TOOL='~/.Q4D/qbitLabeller.py ${Event[$HASH_INDEX]} ${Event[$LABEL_INDEX]}'

import sys
# Dependency: pip install qbittorrent-api
import qbittorrentapi

# Configuration variables for qBittorrent WebUI
host = 'your.qbittorrent.host'  # Replace with your qBittorrent host URL
port = 443  # Replace with your qBittorrent WebUI port
username = 'your_username'  # Replace with your qBittorrent username
password = 'your_password'  # Replace with your qBittorrent password

# Command-line arguments
torrent_hash = sys.argv[1]
label = sys.argv[2]

print(f"Setting label of {torrent_hash} to '{label}'")

# Instantiate a Client using the appropriate WebUI configuration
qbt_client = qbittorrentapi.Client(
    host=host,
    port=port,
    username=username,
    password=password
)

try:
    # Authenticate to the qBittorrent WebUI
    qbt_client.auth_log_in()

    # Check if the label exists, and create it if it doesn't
    existing_labels = qbt_client.torrents_categories()
    if label not in existing_labels:
        qbt_client.torrents_create_category(category=label)

    # Set the label on the specified torrent
    qbt_client.torrents_set_category(torrent_hashes=torrent_hash, category=label)
    print(f"Label '{label}' set successfully for torrent {torrent_hash}")

except qbittorrentapi.LoginFailed as e:
    print(f"Failed to authenticate: {e}")
except Exception as e:
    print(f"An error occurred: {e}")
