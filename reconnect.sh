#!/bin/sh
# 1. Stop the VPN immediately. This instantly severs JDownloader's internet access.
curl -s -X PUT -d '{"status":"stopped"}' http://127.0.0.1:8000/v1/vpn/status > /dev/null

# 2. Fork a background process that waits 2 seconds and then starts the VPN
(sleep 2 && curl -s -X PUT -d '{"status":"running"}' http://127.0.0.1:8000/v1/vpn/status > /dev/null) &

# 3. Exit instantly with success. 
# JDownloader will test its IP, fail (because VPN is down), and enter its built-in retry loop until the VPN comes back up!
exit 0
