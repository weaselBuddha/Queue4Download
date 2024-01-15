# Queue4Download
Scripts have been structured to make customization straight forward, adding in categories, changing torrent client, destination paths, or even the broker should be easy for anyone familiar with Bash scripting.

Uses some of Bash 4.4, been tested on Ubuntu and FreeBSD. This has NOT been tested for any form of Windows or Windows emulation, or OSX. Mosquitto runs on all of them, it is Bash Daemon handling that would be an issue.

Process Tree (1->2->3)

(1) Server:

 rtorrent via rtorrent.rc defined event) event.download.finished
 Deluge, Execute Plugin, /home/user/Scripts/Queue4Download.sh
 Qbittorrent,  Run external program on torrent completion, /home/user/Scripts/Queue4Download.sh "%N" %I %L %T "%F"
       |
       |
      \/
 Queue4Download.sh   --> **EventBus** (Mosquitto MQTT) Push via Publish **-2-**

(2) Client:

 **EventBus** ----> ProcessEvent.sh  Daemon (Mosquitto MQTT) Subscribe  
     /\                          |
      |                          |
      |                          \/
      \--- PUB: ACK -- LFTPtransfer.sh (spawned) **-3-**  --> PAYLOAD (Categorized) 

(3) Server:

 EventBus --(ACK/NACK)--> SetLabel.sh Daemon  --> Update Torrent Label (Done/Error)

Addendum:

rtorrent.rc entry

method.set_key = event.download.finished,complete,"execute.throw.bg=/home/owner/Scripts/Queue4Download.sh,(d.name)"
method.set_key = event.download.finished,complete,"execute.throw.bg=/home/owner/Scripts/Queue4Download.sh,(d.name),(d.hash),(d.custom1),(d.data_path)" (Long Version)

This is all Unix, runs two Daemons, and you have to install Mosquitto (apt-get install mosquitto mosquitto-tools). Client tested on FreeNAS and Thecus. Server should run on any seedbox, may need to compile mosquitto yourself if you don't have root.

Chmura will at request install Mosquitto for you (if you have a Chmura box)

Details in Deleted Thread:

https://www.reddit.com/r/Chmuranet/comments/f3lghf/queue4download_scripts_to_handle_torrent_complete/

NEW:

Tool to handle changing Deluge Label for use in these scripts.

https://www.reddit.com/r/seedboxes/comments/jt9rwg/lftp_how_can_i_pull_files_from_seedbox_to_local/gc7tdku/

Further notes: https://www.reddit.com/r/Chmuranet/comments/f3lghf/queue4download_scripts_to_handle_torrent_complete/
https://www.reddit.com/r/sbtech/comments/nih988/queue4download_scripts_to_handle_torrent_complete/
