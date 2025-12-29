#!/bin/bash

set -euo pipefail

readonly STARLINK_IP="192.168.100.1"
readonly STARLINK_PORT="9200"
readonly UPDATE_INTERVAL=0.1
readonly PING_TIMEOUT=2
readonly PING_COUNT=1

# NTP Configuration
readonly NTP_SERVER="192.168.100.1"         # Starlink NTP server
readonly NTP_TIMEOUT="3"                        # NTP query timeout
readonly NTP_UPDATE_INTERVAL="60"               # Seconds between NTP sync updates
readonly USE_NTP_DISPLAY="true"                 # Display NTP timing information

# Cross-platform timeout command
if command -v gtimeout &> /dev/null; then
    readonly TIMEOUT_CMD="gtimeout"
    readonly USE_TIMEOUT_FOR_GRPC="true"
elif command -v timeout &> /dev/null; then
    readonly TIMEOUT_CMD="timeout"
    # Linux timeout command interferes with grpcurl output buffering
    readonly USE_TIMEOUT_FOR_GRPC="false"
else
    readonly TIMEOUT_CMD=""
    readonly USE_TIMEOUT_FOR_GRPC="false"
fi

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

readonly ESC=$'\033'
readonly CLEAR_LINE="${ESC}[2K"
readonly CLEAR_TO_EOL="${ESC}[K"
readonly HIDE_CURSOR="${ESC}[?25l"
readonly SHOW_CURSOR="${ESC}[?25h"

readonly LAT_ROW=5 LAT_COL=20
readonly LON_ROW=6 LON_COL=20
readonly ALT_ROW=7 ALT_COL=20
readonly ACC_ROW=8 ACC_COL=20
readonly SAT_ROW=11 SAT_COL=20
readonly VALID_ROW=12 VALID_COL=20
readonly DIST_ROW=13 DIST_COL=20
readonly TIME_ROW=16 TIME_COL=20
readonly RUNTIME_ROW=17 RUNTIME_COL=20
readonly RATE_ROW=18 RATE_COL=20
readonly READINGS_ROW=19 READINGS_COL=20
readonly NTP_STATUS_ROW=22 NTP_STATUS_COL=20
readonly NTP_OFFSET_ROW=23 NTP_OFFSET_COL=20
readonly NTP_SYNC_ROW=24 NTP_SYNC_COL=20

start_time=""
initial_lat=""
initial_lon=""
total_readings=0

# NTP Global Variables
NTP_OFFSET="0"                          # NTP time offset in seconds
NTP_LAST_SYNC=""                       # Last NTP sync timestamp
NTP_AVAILABLE="false"                  # NTP server availability status

error_exit() {
    local message="$1"
    local exit_code="${2:-1}"
    echo -e "${COLOR_RED}Error: ${message}${COLOR_NC}" >&2
    exit "${exit_code}"
}

warn() {
    local message="$1"
    echo -e "${COLOR_YELLOW}Warning: ${message}${COLOR_NC}" >&2
}

command_exists() {
    command -v "$1" &> /dev/null
}

goto_xy() {
    local col="$1"
    local row="$2"
    echo -en "${ESC}[${row};${col}H"
}

update_field() {
    local row="$1"
    local col="$2"
    local value="$3"
    goto_xy "${col}" "${row}"
    echo -en "${CLEAR_TO_EOL}${value}"
}

check_dependencies() {
    local missing_deps=()
    
    if ! command_exists grpcurl; then
        missing_deps+=("grpcurl")
    fi
    
    if ! command_exists bc; then
        missing_deps+=("bc")
    fi
    
    if ! command_exists awk; then
        missing_deps+=("awk")
    fi
    
    if [[ "$USE_NTP_DISPLAY" == "true" ]]; then
        if ! command_exists sntp; then
            missing_deps+=("sntp")
        fi
        
        if ! command_exists nc; then
            missing_deps+=("nc")
        fi
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_exit "Missing required dependencies: ${missing_deps[*]}"
    fi
}

check_connectivity() {
    if ! ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${STARLINK_IP}" > /dev/null 2>&1; then
        warn "Cannot ping Starlink at ${STARLINK_IP}"
        warn "Continuing anyway..."
        sleep 2
    fi
}

calculate_distance() {
    local lat1="$1" lon1="$2" lat2="$3" lon2="$4"
    
    awk -v lat1="$lat1" -v lon1="$lon1" -v lat2="$lat2" -v lon2="$lon2" '
        BEGIN {
            PI = 3.14159265359
            dlat = (lat2 - lat1) * PI / 180
            dlon = (lon2 - lon1) * PI / 180
            
            a = sin(dlat/2)^2 + cos(lat1*PI/180) * cos(lat2*PI/180) * sin(dlon/2)^2
            c = 2 * atan2(sqrt(a), sqrt(1-a))
            
            printf "%.2f", 6371000 * c
        }'
}

# =============================================================================
# NTP Functions
# =============================================================================

check_ntp_server() {
    if [[ "$USE_NTP_DISPLAY" != "true" ]]; then
        return 1
    fi
    
    if ${TIMEOUT_CMD} "$NTP_TIMEOUT" nc -u -z "$NTP_SERVER" 123 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

sync_ntp_time() {
    local ntp_result
    local current_time=$(date +%s)
    
    # Skip if recently synced
    if [[ -n "$NTP_LAST_SYNC" ]] && (( current_time - NTP_LAST_SYNC < NTP_UPDATE_INTERVAL )); then
        return 0
    fi
    
    if ! check_ntp_server; then
        NTP_AVAILABLE="false"
        return 1
    fi
    
    # Query NTP server
    if ntp_result=$(${TIMEOUT_CMD} "$NTP_TIMEOUT" sntp -t "$NTP_TIMEOUT" "$NTP_SERVER" 2>&1); then
        # Parse sntp output format:
        # "2025-12-29 09:20:42.513019 (-0500) -0.000077 +/- 0.002686 192.168.100.1 s1 no-leap"
        # The offset is the number before "+/-"
        local offset
        offset=$(echo "$ntp_result" | grep -oE '[-+]?[0-9]+\.[0-9]+ \+/-' | head -1 | awk '{print $1}' 2>/dev/null)

        if [[ -n "$offset" && "$offset" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            NTP_OFFSET="$offset"
            NTP_LAST_SYNC="$current_time"
            NTP_AVAILABLE="true"
            return 0
        fi
    fi
    
    NTP_AVAILABLE="false"
    return 1
}

get_ntp_timestamp() {
    local format="${1:-time}"  # Format: "time" for HHMMSS, "date" for DDMMYY, "datetime" for both
    
    if [[ "$NTP_AVAILABLE" == "true" ]]; then
        # Calculate NTP-corrected time
        local current_epoch=$(date +%s)
        local ntp_epoch=$(echo "scale=3; $current_epoch + $NTP_OFFSET" | bc -l 2>/dev/null || echo "$current_epoch")
        
        case "$format" in
            "time")
                date -u -d "@$ntp_epoch" '+%H:%M:%S' 2>/dev/null || date -u '+%H:%M:%S'
                ;;
            "date")
                date -u -d "@$ntp_epoch" '+%d/%m/%y' 2>/dev/null || date -u '+%d/%m/%y'
                ;;
            "datetime")
                date -u -d "@$ntp_epoch" '+%H:%M:%S %d/%m/%y' 2>/dev/null || date -u '+%H:%M:%S %d/%m/%y'
                ;;
            *)
                date -u -d "@$ntp_epoch" '+%H:%M:%S' 2>/dev/null || date -u '+%H:%M:%S'
                ;;
        esac
    else
        # Use system time
        case "$format" in
            "time")
                date -u '+%H:%M:%S'
                ;;
            "date")
                date -u '+%d/%m/%y'
                ;;
            "datetime")
                date -u '+%H:%M:%S %d/%m/%y'
                ;;
            *)
                date -u '+%H:%M:%S'
                ;;
        esac
    fi
}

get_location_data() {
    local location_json
    location_json=$(grpcurl -plaintext -d '{"get_location":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null)

    if [[ -n "$location_json" ]]; then
        # Use Python for cross-platform JSON parsing
        local parsed
        parsed=$(echo "$location_json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    lla = data.get("getLocation", {}).get("lla", {})
    print(lla.get("lat", ""))
    print(lla.get("lon", ""))
    print(lla.get("alt", ""))
except:
    print("")
    print("")
    print("")
' 2>/dev/null)

        LAT=$(echo "$parsed" | sed -n '1p')
        LON=$(echo "$parsed" | sed -n '2p')
        ALT=$(echo "$parsed" | sed -n '3p')

        # Accuracy field not available in location response
        ACCURACY=""

        if [[ -z "$initial_lat" && -n "$LAT" ]]; then
            initial_lat="$LAT"
            initial_lon="$LON"
        fi
        return 0
    else
        return 1
    fi
}

get_gps_status() {
    local status_json
    status_json=$(grpcurl -plaintext -d '{"get_status":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null)

    if [[ -n "$status_json" ]]; then
        # Use Python for cross-platform JSON parsing
        local parsed
        parsed=$(echo "$status_json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    gps_stats = data.get("dishGetStatus", {}).get("gpsStats", {})
    print(gps_stats.get("gpsSats", "0"))
    print(str(gps_stats.get("gpsValid", False)).lower())
except:
    print("0")
    print("false")
' 2>/dev/null)

        GPS_SATS=$(echo "$parsed" | sed -n '1p')
        GPS_VALID=$(echo "$parsed" | sed -n '2p')

        ((total_readings++))
        return 0
    else
        return 1
    fi
}

initialize_screen() {
    clear
    echo -en "${HIDE_CURSOR}"
    
    # Position cursor at top and display header
    goto_xy 1 1
    echo -e "${COLOR_BOLD}${COLOR_CYAN}STARLINK PNT MONITOR${COLOR_NC}"
    goto_xy 1 2
    echo -e "${COLOR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_NC}"
    
    # Position labels precisely
    goto_xy 1 4
    echo -e "${COLOR_BOLD}POSITION${COLOR_NC}"
    goto_xy 3 5
    echo -e "Latitude:"
    goto_xy 3 6
    echo -e "Longitude:"
    goto_xy 3 7
    echo -e "Altitude:"
    goto_xy 3 8
    echo -e "GPS Status:"
    
    goto_xy 1 10
    echo -e "${COLOR_BOLD}NAVIGATION${COLOR_NC}"
    goto_xy 3 11
    echo -e "Satellites:"
    goto_xy 3 12
    echo -e "GPS Valid:"
    goto_xy 3 13
    echo -e "Distance Moved:"
    
    goto_xy 1 15
    echo -e "${COLOR_BOLD}TIMING${COLOR_NC}"
    goto_xy 3 16
    echo -e "Time:"
    goto_xy 3 17
    echo -e "Runtime:"
    goto_xy 3 18
    echo -e "Update Rate:"
    goto_xy 3 19
    echo -e "Readings:"
    
    if [[ "$USE_NTP_DISPLAY" == "true" ]]; then
        goto_xy 1 21
        echo -e "${COLOR_BOLD}NTP SYNCHRONIZATION${COLOR_NC}"
        goto_xy 3 22
        echo -e "NTP Status:"
        goto_xy 3 23
        echo -e "Time Offset:"
        goto_xy 3 24
        echo -e "Last Sync:"
    fi
    
    goto_xy 1 26
    echo -e "${COLOR_CYAN}Press Ctrl+C to stop${COLOR_NC}"
}

update_position_data() {
    update_field "$LAT_ROW" "$LAT_COL" "${COLOR_GREEN}${LAT:-N/A}°${COLOR_NC}"
    update_field "$LON_ROW" "$LON_COL" "${COLOR_GREEN}${LON:-N/A}°${COLOR_NC}"
    update_field "$ALT_ROW" "$ALT_COL" "${COLOR_GREEN}${ALT:-N/A} m${COLOR_NC}"

    # Show GPS validity status
    local gps_status_text
    if [[ "$GPS_VALID" == "true" ]]; then
        gps_status_text="${COLOR_GREEN}Valid${COLOR_NC}"
    elif [[ "$GPS_VALID" == "false" ]]; then
        gps_status_text="${COLOR_RED}Invalid${COLOR_NC}"
    else
        gps_status_text="${COLOR_YELLOW}Unknown${COLOR_NC}"
    fi
    update_field "$ACC_ROW" "$ACC_COL" "$gps_status_text"
}

update_navigation_data() {
    update_field "$SAT_ROW" "$SAT_COL" "${COLOR_GREEN}${GPS_SATS:-0}${COLOR_NC}"
    
    local gps_status_text
    if [[ "$GPS_VALID" == "true" ]]; then
        gps_status_text="${COLOR_GREEN}Yes${COLOR_NC}"
    else
        gps_status_text="${COLOR_RED}No${COLOR_NC}"
    fi
    update_field "$VALID_ROW" "$VALID_COL" "$gps_status_text"
    
    if [[ -n "$LAT" && -n "$initial_lat" ]]; then
        local distance
        distance=$(calculate_distance "$initial_lat" "$initial_lon" "$LAT" "$LON")
        update_field "$DIST_ROW" "$DIST_COL" "${distance} m"
    else
        update_field "$DIST_ROW" "$DIST_COL" "N/A"
    fi
}

update_timing_data() {
    # Display NTP time if available, otherwise system time
    if [[ "$USE_NTP_DISPLAY" == "true" && "$NTP_AVAILABLE" == "true" ]]; then
        local ntp_time
        ntp_time=$(get_ntp_timestamp "time")
        update_field "$TIME_ROW" "$TIME_COL" "${COLOR_GREEN}${ntp_time} UTC (NTP)${COLOR_NC}"
    else
        update_field "$TIME_ROW" "$TIME_COL" "${COLOR_GREEN}$(date '+%H:%M:%S.%3N')${COLOR_NC}"
    fi
    
    local runtime=$(($(date +%s) - start_time))
    local hours=$((runtime / 3600))
    local minutes=$(((runtime % 3600) / 60))
    local seconds=$((runtime % 60))
    update_field "$RUNTIME_ROW" "$RUNTIME_COL" "$(printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds")"
    
    local rate
    rate=$(echo "scale=1; 1 / $UPDATE_INTERVAL" | bc)
    update_field "$RATE_ROW" "$RATE_COL" "${rate} Hz"
    
    update_field "$READINGS_ROW" "$READINGS_COL" "$total_readings"
}

update_ntp_data() {
    if [[ "$USE_NTP_DISPLAY" != "true" ]]; then
        return
    fi
    
    # NTP Status
    local ntp_status_text
    if [[ "$NTP_AVAILABLE" == "true" ]]; then
        ntp_status_text="${COLOR_GREEN}SYNCHRONIZED${COLOR_NC}"
    else
        ntp_status_text="${COLOR_RED}UNAVAILABLE${COLOR_NC}"
    fi
    update_field "$NTP_STATUS_ROW" "$NTP_STATUS_COL" "$ntp_status_text"
    
    # Time Offset
    if [[ "$NTP_AVAILABLE" == "true" && -n "$NTP_OFFSET" ]]; then
        local ntp_offset_ms
        # Use awk for more reliable floating point calculation
        ntp_offset_ms=$(echo "$NTP_OFFSET" | awk '{printf "%.0f", $1 * 1000}' 2>/dev/null || echo "0")
        # Ensure we have a valid number
        if [[ -n "$ntp_offset_ms" && "$ntp_offset_ms" =~ ^[-+]?[0-9]+$ ]]; then
            update_field "$NTP_OFFSET_ROW" "$NTP_OFFSET_COL" "${COLOR_GREEN}${ntp_offset_ms} ms${COLOR_NC}"
        else
            update_field "$NTP_OFFSET_ROW" "$NTP_OFFSET_COL" "${COLOR_GREEN}< 1 ms${COLOR_NC}"
        fi
    else
        update_field "$NTP_OFFSET_ROW" "$NTP_OFFSET_COL" "N/A"
    fi
    
    # Last Sync
    if [[ "$NTP_AVAILABLE" == "true" && -n "$NTP_LAST_SYNC" ]]; then
        local last_sync_time
        # Cross-platform date formatting (macOS uses -r, Linux uses -d)
        if date -r "$NTP_LAST_SYNC" '+%H:%M:%S' &>/dev/null; then
            last_sync_time=$(date -r "$NTP_LAST_SYNC" '+%H:%M:%S')
        else
            last_sync_time=$(date -d "@$NTP_LAST_SYNC" '+%H:%M:%S' 2>/dev/null || echo "N/A")
        fi
        local sync_age=$(($(date +%s) - NTP_LAST_SYNC))
        update_field "$NTP_SYNC_ROW" "$NTP_SYNC_COL" "${COLOR_GREEN}${last_sync_time} (${sync_age}s ago)${COLOR_NC}"
    else
        update_field "$NTP_SYNC_ROW" "$NTP_SYNC_COL" "Never"
    fi
}

monitor_pnt() {
    start_time=$(date +%s)
    initialize_screen
    
    # Initialize NTP synchronization if enabled
    if [[ "$USE_NTP_DISPLAY" == "true" ]]; then
        sync_ntp_time || true  # Don't fail if NTP is not available
    fi
    
    local last_ntp_sync_time=$start_time
    
    trap 'echo -en "${SHOW_CURSOR}"; goto_xy 1 27; echo; exit 0' EXIT INT TERM
    
    while true; do
        local loop_start_time
        loop_start_time=$(date +%s.%N)

        LAT="" LON="" ALT="" ACCURACY="" GPS_SATS="" GPS_VALID=""
        
        # Periodic NTP synchronization
        if [[ "$USE_NTP_DISPLAY" == "true" ]]; then
            local current_time=$(date +%s)
            if (( current_time - last_ntp_sync_time >= NTP_UPDATE_INTERVAL )); then
                sync_ntp_time || true  # Don't fail if NTP sync fails
                last_ntp_sync_time=$current_time
            fi
        fi
        
        get_location_data 2>/dev/null || true
        get_gps_status 2>/dev/null || true
        
        update_position_data
        update_navigation_data
        update_timing_data
        
        if [[ "$USE_NTP_DISPLAY" == "true" ]]; then
            update_ntp_data
        fi
        
        local loop_end_time
        loop_end_time=$(date +%s.%N)
        local process_time
        process_time=$(echo "$loop_end_time - $loop_start_time" | bc)
        local sleep_time
        sleep_time=$(echo "$UPDATE_INTERVAL - $process_time" | bc)
        
        if (( $(echo "$sleep_time > 0" | bc -l) )); then
            sleep "$sleep_time"
        fi
    done
}

main() {
    echo -e "${COLOR_BOLD}${COLOR_CYAN}Starlink PNT Monitor v2.1${COLOR_NC}"
    if [[ "$USE_NTP_DISPLAY" == "true" ]]; then
        echo -e "${COLOR_CYAN}Initializing with NTP synchronization...${COLOR_NC}\n"
    else
        echo -e "${COLOR_CYAN}Initializing...${COLOR_NC}\n"
    fi
    
    check_dependencies
    check_connectivity
    
    monitor_pnt
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi