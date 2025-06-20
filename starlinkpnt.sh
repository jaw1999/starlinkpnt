#!/bin/bash

set -euo pipefail

readonly STARLINK_IP="192.168.100.1"
readonly STARLINK_PORT="9200"
readonly UPDATE_INTERVAL=0.1
readonly PING_TIMEOUT=2
readonly PING_COUNT=1

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

readonly ESC=$'\033'
readonly CLEAR_LINE="${ESC}[2K"
readonly HIDE_CURSOR="${ESC}[?25l"
readonly SHOW_CURSOR="${ESC}[?25h"

readonly LAT_ROW=5 LAT_COL=15
readonly LON_ROW=6 LON_COL=15
readonly ALT_ROW=7 ALT_COL=15
readonly ACC_ROW=8 ACC_COL=15
readonly SAT_ROW=11 SAT_COL=15
readonly VALID_ROW=12 VALID_COL=15
readonly DIST_ROW=13 DIST_COL=18
readonly TIME_ROW=16 TIME_COL=15
readonly RUNTIME_ROW=17 RUNTIME_COL=15
readonly RATE_ROW=18 RATE_COL=15
readonly READINGS_ROW=19 READINGS_COL=15

declare -g start_time=""
declare -g initial_lat=""
declare -g initial_lon=""
declare -g total_readings=0

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
    echo -en "${CLEAR_LINE}${value}"
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

get_location_data() {
    local location_json
    location_json=$(grpcurl -plaintext -d '{"get_location":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null)
    
    if [[ -n "$location_json" ]]; then
        LAT=$(echo "$location_json" | grep -oP '"lat":\s*\K[-0-9.]+' || echo "")
        LON=$(echo "$location_json" | grep -oP '"lon":\s*\K[-0-9.]+' || echo "")
        ALT=$(echo "$location_json" | grep -oP '"alt":\s*\K[-0-9.]+' || echo "")
        ACCURACY=$(echo "$location_json" | grep -oP '"sigmaM":\s*\K[-0-9.]+' || echo "")
        
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
        GPS_SATS=$(echo "$status_json" | grep -oP '"gpsSats":\s*\K[0-9]+' || echo "0")
        GPS_VALID=$(echo "$status_json" | grep -oP '"gpsValid":\s*\K(true|false)' || echo "false")
        
        ((total_readings++))
        return 0
    else
        return 1
    fi
}

initialize_screen() {
    clear
    echo -en "${HIDE_CURSOR}"
    
    echo -e "${COLOR_BOLD}${COLOR_CYAN}STARLINK PNT MONITOR${COLOR_NC}"
    echo -e "${COLOR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_NC}"
    
    echo -e "\n${COLOR_BOLD}POSITION${COLOR_NC}"
    echo -e "  Latitude:"
    echo -e "  Longitude:"
    echo -e "  Altitude:"
    echo -e "  Accuracy:"
    
    echo -e "\n${COLOR_BOLD}NAVIGATION${COLOR_NC}"
    echo -e "  Satellites:"
    echo -e "  GPS Valid:"
    echo -e "  Distance Moved:"
    
    echo -e "\n${COLOR_BOLD}TIMING${COLOR_NC}"
    echo -e "  Time:"
    echo -e "  Runtime:"
    echo -e "  Update Rate:"
    echo -e "  Readings:"
    
    echo -e "\n${COLOR_CYAN}Press Ctrl+C to stop${COLOR_NC}"
}

update_position_data() {
    update_field "$LAT_ROW" "$LAT_COL" "${COLOR_GREEN}${LAT:-N/A}°${COLOR_NC}"
    update_field "$LON_ROW" "$LON_COL" "${COLOR_GREEN}${LON:-N/A}°${COLOR_NC}"
    update_field "$ALT_ROW" "$ALT_COL" "${COLOR_GREEN}${ALT:-N/A} m${COLOR_NC}"
    update_field "$ACC_ROW" "$ACC_COL" "±${ACCURACY:-N/A} m"
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
    update_field "$TIME_ROW" "$TIME_COL" "${COLOR_GREEN}$(date '+%H:%M:%S.%3N')${COLOR_NC}"
    
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

monitor_pnt() {
    start_time=$(date +%s)
    initialize_screen
    
    trap 'echo -en "${SHOW_CURSOR}"; goto_xy 1 20; echo; exit 0' EXIT INT TERM
    
    while true; do
        local loop_start_time
        loop_start_time=$(date +%s.%N)
        
        local LAT LON ALT ACCURACY GPS_SATS GPS_VALID
        
        get_location_data || warn "Failed to get location data"
        get_gps_status || warn "Failed to get GPS status"
        
        update_position_data
        update_navigation_data
        update_timing_data
        
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
    echo -e "${COLOR_BOLD}${COLOR_CYAN}Starlink PNT Monitor v2.0${COLOR_NC}"
    echo -e "${COLOR_CYAN}Initializing...${COLOR_NC}\n"
    
    check_dependencies
    check_connectivity
    
    monitor_pnt
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi