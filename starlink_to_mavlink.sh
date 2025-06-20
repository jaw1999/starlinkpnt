#!/bin/bash

set +e 
set +u  

readonly STARLINK_IP="192.168.100.1"
readonly STARLINK_PORT="9200"
readonly UPDATE_INTERVAL=0.1  # 10Hz update rate for MAVLink
readonly MAVLINK_UDP_IP="127.0.0.1"
readonly MAVLINK_UDP_PORT="14550"
readonly MAVLINK_SYSTEM_ID="01"
readonly MAVLINK_COMPONENT_ID="dc"  # MAV_COMP_ID_GPS (220 = 0xDC)
readonly DEBUG_MODE="${DEBUG_MAVLINK:-false}"

# Global variables for GPS data
LAT=""
LON=""
ALT=""
ACCURACY=""
GPS_SATS="0"
GPS_VALID="false"
SEQUENCE_NUMBER=0

error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    echo "Error: ${message}" >&2
    exit "${exit_code}"
}

warn() {
    local message="$1"
    echo "Warning: ${message}" >&2
}

command_exists() {
    command -v "$1" &> /dev/null
}

check_dependencies() {
    local missing_deps=()
    
    if ! command_exists grpcurl; then
        missing_deps+=("grpcurl")
    fi
    
    if ! command_exists bc; then
        missing_deps+=("bc")
    fi
    
    if ! command_exists nc; then
        missing_deps+=("nc (netcat)")
    fi
    
    if ! command_exists python3; then
        missing_deps+=("python3")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_exit "Missing required dependencies: ${missing_deps[*]}"
    fi
}

# Get current timestamp in microseconds since Unix epoch
get_timestamp_us() {
    python3 -c "import time; print(int(time.time() * 1000000))"
}

# Get current timestamp in milliseconds since Unix epoch  
get_timestamp_ms() {
    python3 -c "import time; print(int(time.time() * 1000))"
}

get_starlink_data() {
    local location_json=""
    local status_json=""
    
    # Reset variables
    LAT=""
    LON=""
    ALT=""
    ACCURACY=""
    GPS_SATS="0"
    GPS_VALID="false"
    
    # Get location data
    if location_json=$(timeout 3 grpcurl -plaintext -d '{"get_location":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null); then
        
        if status_json=$(timeout 3 grpcurl -plaintext -d '{"get_status":{}}' \
            "${STARLINK_IP}:${STARLINK_PORT}" \
            SpaceX.API.Device.Device/Handle 2>/dev/null); then
            
            if [[ -n "$location_json" && -n "$status_json" ]]; then
                # Parse location data
                LAT=$(echo "$location_json" | grep -oP '"lat":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                LON=$(echo "$location_json" | grep -oP '"lon":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                ALT=$(echo "$location_json" | grep -oP '"alt":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                ACCURACY=$(echo "$location_json" | grep -oP '"sigmaM":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                
                # Parse GPS status
                GPS_SATS=$(echo "$status_json" | grep -oP '"gpsSats":\s*\K[0-9]+' 2>/dev/null || echo "0")
                GPS_VALID=$(echo "$status_json" | grep -oP '"gpsValid":\s*\K(true|false)' 2>/dev/null || echo "false")
                
                return 0
            fi
        fi
    fi
    
    return 1
}

# Calculate CRC for MAVLink v1 messages with CRC_EXTRA
calculate_mavlink_crc() {
    local header_and_payload="$1"
    local crc_extra="$2"
    python3 -c "
import sys
try:
    data = bytes.fromhex('$header_and_payload')
    crc_extra = $crc_extra
    crc = 0xFFFF

    # Process header and payload
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1

    # Add CRC_EXTRA
    crc ^= crc_extra
    for _ in range(8):
        if crc & 1:
            crc = (crc >> 1) ^ 0xA001
        else:
            crc >>= 1

    print(f'{crc & 0xFF:02x}{(crc >> 8) & 0xFF:02x}')
except Exception as e:
    print('0000')
"
}

# Convert degrees to 1E7 format used by MAVLink
degrees_to_1e7() {
    local degrees="$1"
    if [[ -n "$degrees" && "$degrees" != "0" && "$degrees" != "" ]]; then
        python3 -c "
try:
    print(int(float('$degrees') * 10000000))
except:
    print(0)
"
    else
        echo "0"
    fi
}

# Convert meters to millimeters
meters_to_mm() {
    local meters="$1"
    if [[ -n "$meters" && "$meters" != "" ]]; then
        python3 -c "
try:
    print(int(float('$meters') * 1000))
except:
    print(0)
"
    else
        echo "0"
    fi
}

# Generate MAVLink HEARTBEAT message (message ID 0)
generate_heartbeat() {
    local payload="060000000000"  # type=MAV_TYPE_GCS, autopilot=MAV_AUTOPILOT_INVALID, base_mode=0, custom_mode=0, system_status=MAV_STATE_STANDBY
    local msg_len="06"
    local msg_id="00"
    local seq=$(printf "%02x" $((SEQUENCE_NUMBER % 256)))
    local crc_extra="50"  # CRC_EXTRA for HEARTBEAT
    
    local header="fe${msg_len}${seq}${MAVLINK_SYSTEM_ID}${MAVLINK_COMPONENT_ID}${msg_id}"
    local crc=$(calculate_mavlink_crc "${header}${payload}" $((0x$crc_extra)))
    
    echo "${header}${payload}${crc}"
}

# Generate MAVLink GPS_RAW_INT message (message ID 24)
generate_gps_raw_int() {
    local timestamp=$(get_timestamp_us)
    local lat_1e7=$(degrees_to_1e7 "$LAT")
    local lon_1e7=$(degrees_to_1e7 "$LON")
    local alt_mm=$(meters_to_mm "$ALT")
    
    # GPS fix type: 0=no fix, 1=no fix, 2=2D fix, 3=3D fix
    local fix_type="0"
    if [[ "$GPS_VALID" == "true" ]]; then
        if [[ "$GPS_SATS" -gt 3 ]]; then
            fix_type="3"  # 3D fix
        else
            fix_type="2"  # 2D fix
        fi
    fi
    
    # Convert accuracy to cm (MAVLink uses cm for position accuracy)
    local eph="65535"  # UINT16_MAX if unknown
    local epv="65535"  # UINT16_MAX if unknown
    if [[ -n "$ACCURACY" && "$ACCURACY" != "0" && "$ACCURACY" != "" ]]; then
        eph=$(python3 -c "
try:
    print(min(65534, int(float('$ACCURACY') * 100)))
except:
    print(65535)
")
        epv="$eph"
    fi
    
    local vel="65535"      # velocity in cm/s (unknown)
    local cog="65535"      # course over ground in centidegrees (unknown)
    
    # Ensure GPS_SATS is a valid number
    if [[ ! "$GPS_SATS" =~ ^[0-9]+$ ]]; then
        GPS_SATS="0"
    fi
    
    # Pack the message (little endian format)
    local payload=$(python3 -c "
import struct
try:
    timestamp = $timestamp
    lat = $lat_1e7
    lon = $lon_1e7
    alt = $alt_mm
    eph = $eph
    epv = $epv
    vel = $vel
    cog = $cog
    fix_type = $fix_type
    satellites_visible = $GPS_SATS

    data = struct.pack('<QiiiHHHHBB', timestamp, lat, lon, alt, eph, epv, vel, cog, fix_type, satellites_visible)
    print(data.hex())
except Exception as e:
    print('00' * 60)  # fallback payload (30 bytes * 2 hex chars)
")
    
    local msg_len="1e"  # 30 bytes
    local msg_id="18"   # GPS_RAW_INT = 24 = 0x18
    local seq=$(printf "%02x" $((SEQUENCE_NUMBER % 256)))
    local crc_extra="24"  # CRC_EXTRA for GPS_RAW_INT
    
    local header="fe${msg_len}${seq}${MAVLINK_SYSTEM_ID}${MAVLINK_COMPONENT_ID}${msg_id}"
    local crc=$(calculate_mavlink_crc "${header}${payload}" $((0x$crc_extra)))
    
    echo "${header}${payload}${crc}"
}

# Generate MAVLink GLOBAL_POSITION_INT message (message ID 33)
generate_global_position_int() {
    local timestamp=$(get_timestamp_ms)
    local lat_1e7=$(degrees_to_1e7 "$LAT")
    local lon_1e7=$(degrees_to_1e7 "$LON")
    local alt_mm=$(meters_to_mm "$ALT")
    local relative_alt_mm="$alt_mm"  # Assume same as absolute for now
    
    # Velocities (unknown, set to 0)
    local vx="0"
    local vy="0" 
    local vz="0"
    local hdg="65535"  # heading in centidegrees (unknown)
    
    local payload=$(python3 -c "
import struct
try:
    timestamp = $timestamp
    lat = $lat_1e7
    lon = $lon_1e7
    alt = $alt_mm
    relative_alt = $relative_alt_mm
    vx = $vx
    vy = $vy
    vz = $vz
    hdg = $hdg

    data = struct.pack('<IiiihhhH', timestamp, lat, lon, alt, relative_alt, vx, vy, vz, hdg)
    print(data.hex())
except Exception as e:
    print('00' * 56)  # fallback payload (28 bytes * 2 hex chars)
")
    
    local msg_len="1c"  # 28 bytes
    local msg_id="21"   # GLOBAL_POSITION_INT = 33 = 0x21
    local seq=$(printf "%02x" $((SEQUENCE_NUMBER % 256)))
    local crc_extra="104"  # CRC_EXTRA for GLOBAL_POSITION_INT
    
    local header="fe${msg_len}${seq}${MAVLINK_SYSTEM_ID}${MAVLINK_COMPONENT_ID}${msg_id}"
    local crc=$(calculate_mavlink_crc "${header}${payload}" $((0x$crc_extra)))
    
    echo "${header}${payload}${crc}"
}

# Generate MAVLink GPS_STATUS message (message ID 25)
generate_gps_status() {
    # Ensure GPS_SATS is a valid number
    if [[ ! "$GPS_SATS" =~ ^[0-9]+$ ]]; then
        GPS_SATS="0"
    fi
    
    local payload=$(python3 -c "
import struct
try:
    satellites_visible = $GPS_SATS
    
    # Create arrays for satellite data (20 satellites max)
    sat_prn = []
    sat_used = []
    sat_elevation = []
    sat_azimuth = []
    sat_snr = []
    
    for i in range(20):
        if i < satellites_visible:
            sat_prn.append(i + 1)      # PRN 1-20
            sat_used.append(1)         # Used
            sat_elevation.append(45)   # 45 degrees
            sat_azimuth.append(i * 18) # Spread around 360 degrees
            sat_snr.append(30)         # 30 dB
        else:
            sat_prn.append(0)
            sat_used.append(0)
            sat_elevation.append(0)
            sat_azimuth.append(0)
            sat_snr.append(0)
    
    # Pack the data: 1 byte for sat count + 20*5 bytes for sat data
    data = struct.pack('<B', satellites_visible)
    data += struct.pack('<20B', *sat_prn)
    data += struct.pack('<20B', *sat_used)  
    data += struct.pack('<20B', *sat_elevation)
    data += struct.pack('<20B', *sat_azimuth)
    data += struct.pack('<20B', *sat_snr)
    
    print(data.hex())
except Exception as e:
    print('00' * 202)  # fallback payload (101 bytes * 2 hex chars)
")
    
    local msg_len="65"  # 101 bytes
    local msg_id="19"   # GPS_STATUS = 25 = 0x19
    local seq=$(printf "%02x" $((SEQUENCE_NUMBER % 256)))
    local crc_extra="23"  # CRC_EXTRA for GPS_STATUS
    
    local header="fe${msg_len}${seq}${MAVLINK_SYSTEM_ID}${MAVLINK_COMPONENT_ID}${msg_id}"
    local crc=$(calculate_mavlink_crc "${header}${payload}" $((0x$crc_extra)))
    
    echo "${header}${payload}${crc}"
}

# Send MAVLink message via UDP
send_mavlink_message() {
    local message="$1"
    local msg_type="$2"
    
    # Validate that message is valid hex and has reasonable length
    if [[ "$message" =~ ^[0-9a-fA-F]+$ && ${#message} -ge 16 && $((${#message} % 2)) -eq 0 ]]; then
        # Use python to convert hex to binary and send via UDP
        local result=$(python3 -c "
import socket
import sys
try:
    data = bytes.fromhex('$message')
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.sendto(data, ('$MAVLINK_UDP_IP', $MAVLINK_UDP_PORT))
    sock.close()
    print('OK')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)
        
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo "DEBUG: Sent ${msg_type:-Unknown} (${#message} chars) -> $result"
        fi
    else
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo "DEBUG: Invalid message format for ${msg_type:-Unknown}: length=${#message}"
        fi
    fi
}

cleanup() {
    echo "Cleaning up..."
    exit 0
}

main() {
    echo "Starlink to MAVLink Bridge"
    echo "========================="
    
    check_dependencies
    
    trap cleanup EXIT INT TERM
    
    echo "Starting MAVLink data stream from Starlink..."
    echo "Update rate: $(echo "1 / $UPDATE_INTERVAL" | bc -l | cut -d. -f1) Hz"
    echo "MAVLink output: UDP ${MAVLINK_UDP_IP}:${MAVLINK_UDP_PORT}"
    echo "System ID: ${MAVLINK_SYSTEM_ID}, Component ID: ${MAVLINK_COMPONENT_ID}"
    echo "Debug mode: ${DEBUG_MODE} (set DEBUG_MAVLINK=true for verbose output)"
    echo "Press Ctrl+C to stop"
    echo
    
    local count=0
    local successful_reads=0
    local failed_reads=0
    local last_status_time=$(date +%s)
    local heartbeat_counter=0
    local msgs_sent=0

    while true; do
        # Get Starlink data
        if get_starlink_data; then
            ((successful_reads++))
        else
            ((failed_reads++))
        fi
        
        # Send heartbeat every 1 second (10 cycles at 10Hz)
        if (( heartbeat_counter % 10 == 0 )); then
            local heartbeat=$(generate_heartbeat 2>/dev/null)
            if [[ -n "$heartbeat" ]]; then
                send_mavlink_message "$heartbeat" "HEARTBEAT"
                ((msgs_sent++))
            fi
        fi
        
        # Always send GPS messages
        local gps_raw=$(generate_gps_raw_int 2>/dev/null)
        if [[ -n "$gps_raw" ]]; then
            send_mavlink_message "$gps_raw" "GPS_RAW_INT"
            ((msgs_sent++))
        fi
        
        # Send global position if we have valid GPS
        if [[ "$GPS_VALID" == "true" && -n "$LAT" && -n "$LON" ]]; then
            local global_pos=$(generate_global_position_int 2>/dev/null)
            if [[ -n "$global_pos" ]]; then
                send_mavlink_message "$global_pos" "GLOBAL_POSITION_INT"
                ((msgs_sent++))
            fi
        fi
        
        # Send GPS status every 5 cycles
        if (( count % 5 == 0 )); then
            local gps_status=$(generate_gps_status 2>/dev/null)
            if [[ -n "$gps_status" ]]; then
                send_mavlink_message "$gps_status" "GPS_STATUS"
                ((msgs_sent++))
            fi
        fi
        
        ((SEQUENCE_NUMBER++))
        ((count++))
        ((heartbeat_counter++))
        
        # Status update every 10 seconds
        local current_time=$(date +%s)
        if (( current_time - last_status_time >= 10 )); then
            local rate=$(echo "scale=1; $count / 10" | bc -l)
            local msg_rate=$(echo "scale=1; $msgs_sent / 10" | bc -l)
            echo "$(date '+%H:%M:%S'): $count cycles (${rate}/s) | MAVLink msgs: $msgs_sent (${msg_rate}/s) | GPS: Sats=$GPS_SATS Valid=$GPS_VALID | Starlink: OK=$successful_reads Fail=$failed_reads"
            last_status_time=$current_time
            count=0
            msgs_sent=0
        fi
        
        sleep "$UPDATE_INTERVAL" 2>/dev/null || sleep 0.1
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 