#!/bin/bash

# Test script for MAVLink output from starlink_to_mavlink.sh
# This script listens on the MAVLink UDP port and displays received messages

readonly MAVLINK_UDP_PORT="14550"
readonly TEST_DURATION="30"

echo "MAVLink Test Listener"
echo "===================="
echo "Listening on UDP port $MAVLINK_UDP_PORT for $TEST_DURATION seconds"
echo "Press Ctrl+C to stop early"
echo
echo "Expected MAVLink v1 messages:"
echo "- HEARTBEAT (ID 0): Every 1 second"
echo "- GPS_RAW_INT (ID 24): Every 0.1 seconds"
echo "- GLOBAL_POSITION_INT (ID 33): When GPS is valid"
echo "- GPS_STATUS (ID 25): Every 0.5 seconds"
echo
echo "Raw hexadecimal output:"
echo "----------------------"

# Function to decode MAVLink message type
decode_mavlink() {
    while IFS= read -r line; do
        # Look for MAVLink v1 messages (start with 0xFE)
        if [[ "$line" =~ ^[0-9a-f]*fe[0-9a-f]{10}([0-9a-f]{2}) ]]; then
            msg_id_hex="${BASH_REMATCH[1]}"
            msg_id=$((16#$msg_id_hex))
            
            case $msg_id in
                0)  echo "$line  <- HEARTBEAT" ;;
                24) echo "$line  <- GPS_RAW_INT" ;;
                25) echo "$line  <- GPS_STATUS" ;;
                33) echo "$line  <- GLOBAL_POSITION_INT" ;;
                *)  echo "$line  <- Unknown message ID: $msg_id" ;;
            esac
        else
            echo "$line"
        fi
    done
}

# Start listening and pipe through decoder
timeout "$TEST_DURATION" nc -ul "$MAVLINK_UDP_PORT" | hexdump -v -e '/1 "%02x"' -e '/32 "\n"' | decode_mavlink

echo
echo "Test completed. If no messages were received:"
echo "1. Make sure starlink_to_mavlink.sh is running"
echo "2. Check that the UDP port matches ($MAVLINK_UDP_PORT)"
echo "3. Verify firewall is not blocking the port" 