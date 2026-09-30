#!/usr/bin/python3

# qbitLabeller.py - by /u/rj_d2 with thanks (https://www.reddit.com/r/sbtech/comments/1ams0hn/q4d_updated/l9nkq4y/)
#
# usage: qbitLabeller.py <torrent-hash> <label>
#
# Edit this tool to reflect your qBittorrent settings (host, port, user, pw)

import sys
# Dependency: pip install qbittorrentapi
import qbittorrentapi

# Configuration variables for qBittorrent WebUI
host = 'your.qbittorrent.host'  # Replace with your qBittorrent host URL
port = 443  # Replace with your qBittorrent WebUI port
username = 'your_username'  # Replace with your qBittorrent username
password = 'your_password'  # Replace with your qBittorrent password

if len(sys.argv) != 3:
    print("usage: qbitLabeller.py <torrent-hash> <label>")
    sys.exit(2)

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
    sys.exit(1)
except Exception as e:
    print(f"An error occurred: {e}")
    sys.exit(1)
