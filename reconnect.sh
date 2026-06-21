#!/bin/sh
# This script sends a restart command to the Gluetun API to fetch a new IP address.
# Because JDownloader runs in the same network namespace as Gluetun, it can access localhost.

# Stop the VPN connection
curl -s -X PUT -d '{"status":"stopped"}' http://127.0.0.1:8000/v1/vpn/status > /dev/null

# Wait a moment for it to tear down
sleep 2

# Start the VPN connection
curl -s -X PUT -d '{"status":"running"}' http://127.0.0.1:8000/v1/vpn/status > /dev/null

# Give it a few seconds to establish the handshake before JDownloader resumes downloading
sleep 5
