#!/bin/bash

set +e
set +u

readonly STARLINK_IP="192.168.100.1"
readonly STARLINK_PORT="9200"
readonly UPDATE_INTERVAL=0.2
readonly GPS_PIPE="/tmp/starlink_nmea"

# Cross-platform timeout command
if command -v gtimeout &> /dev/null; then
    readonly TIMEOUT_CMD="gtimeout"
elif command -v timeout &> /dev/null; then
    readonly TIMEOUT_CMD="timeout"
else
    readonly TIMEOUT_CMD=""
fi

LAT=""
LON=""
ALT=""
ACCURACY=""
GPS_SATS="0"
GPS_VALID="false"

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
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_exit "Missing required dependencies: ${missing_deps[*]}"
    fi
}

calculate_checksum() {
    local sentence="$1"
    local checksum=0
    local i
    
    for ((i=1; i<${#sentence}; i++)); do
        if printf -v ascii "%d" "'${sentence:$i:1}" 2>/dev/null; then
            checksum=$((checksum ^ ascii))
        fi
    done
    
    printf "%02X" "$checksum"
}

get_starlink_data() {
    local location_json=""
    local status_json=""

    LAT=""
    LON=""
    ALT=""
    ACCURACY=""
    GPS_SATS="0"
    GPS_VALID="false"

    # Get location data
    if location_json=$(${TIMEOUT_CMD} 3 grpcurl -plaintext -d '{"get_location":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null); then

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
        fi
    fi

    # Get GPS status data
    if status_json=$(${TIMEOUT_CMD} 3 grpcurl -plaintext -d '{"get_status":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null); then

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
        fi
    fi

    # Return success if we got any data
    if [[ -n "$LAT" && -n "$LON" ]]; then
        return 0
    else
        return 1
    fi
}

convert_to_dms() {
    local decimal="$1"
    local is_longitude="$2"
    
    if [[ -z "$decimal" || "$decimal" == "0" ]]; then
        if [[ "$is_longitude" == "true" ]]; then
            echo "00000.0000,E"
        else
            echo "0000.0000,N"
        fi
        return
    fi
    

    local abs_decimal degrees minutes_decimal hemisphere
    
    if abs_decimal=$(echo "$decimal" | sed 's/^-//' 2>/dev/null); then
        if degrees=$(echo "$abs_decimal" | cut -d. -f1 2>/dev/null); then
            if minutes_decimal=$(echo "($abs_decimal - $degrees) * 60" | bc -l 2>/dev/null); then
                
                if [[ "$is_longitude" == "true" ]]; then
                    if (( $(echo "$decimal >= 0" | bc -l 2>/dev/null || echo "1") )); then
                        hemisphere="E"
                    else
                        hemisphere="W"
                    fi
                    printf "%03d%07.4f,%s" "$degrees" "$minutes_decimal" "$hemisphere" 2>/dev/null || echo "00000.0000,E"
                else
                    if (( $(echo "$decimal >= 0" | bc -l 2>/dev/null || echo "1") )); then
                        hemisphere="N"
                    else
                        hemisphere="S"
                    fi
                    printf "%02d%07.4f,%s" "$degrees" "$minutes_decimal" "$hemisphere" 2>/dev/null || echo "0000.0000,N"
                fi
                return
            fi
        fi
    fi
    

    if [[ "$is_longitude" == "true" ]]; then
        echo "00000.0000,E"
    else
        echo "0000.0000,N"
    fi
}

generate_nmea_gga() {
    local timestamp
    timestamp=$(date -u '+%H%M%S' 2>/dev/null || echo "000000")
    
    if [[ "$GPS_VALID" == "true" && -n "$LAT" && -n "$LON" && "$LAT" != "0" && "$LON" != "0" ]]; then

        local lat_dms lon_dms quality hdop
        lat_dms=$(convert_to_dms "$LAT" "false")
        lon_dms=$(convert_to_dms "$LON" "true")
        
        quality="1"
        hdop=$(echo "scale=1; if ($ACCURACY > 0) $ACCURACY / 5 else 1.0" | bc -l 2>/dev/null || echo "1.0")
        
        local gga_sentence="\$GPGGA,${timestamp},${lat_dms},${lon_dms},${quality},${GPS_SATS},${hdop},${ALT:-0.0},M,0.0,M,,"
        local gga_checksum=$(calculate_checksum "$gga_sentence")
        echo "${gga_sentence}*${gga_checksum}"
    else

        local gga_sentence="\$GPGGA,${timestamp},,,,0,${GPS_SATS},,0.0,M,0.0,M,,"
        local gga_checksum=$(calculate_checksum "$gga_sentence")
        echo "${gga_sentence}*${gga_checksum}"
    fi
}

generate_nmea_rmc() {
    local timestamp datestamp
    timestamp=$(date -u '+%H%M%S' 2>/dev/null || echo "000000")
    datestamp=$(date -u '+%d%m%y' 2>/dev/null || echo "010100")
    
    if [[ "$GPS_VALID" == "true" && -n "$LAT" && -n "$LON" && "$LAT" != "0" && "$LON" != "0" ]]; then

        local lat_dms lon_dms speed course
        lat_dms=$(convert_to_dms "$LAT" "false")
        lon_dms=$(convert_to_dms "$LON" "true")
        speed="0.0"
        course="0.0"
        
        local rmc_sentence="\$GPRMC,${timestamp},A,${lat_dms},${lon_dms},${speed},${course},${datestamp},,,"
        local rmc_checksum=$(calculate_checksum "$rmc_sentence")
        echo "${rmc_sentence}*${rmc_checksum}"
    else

        local rmc_sentence="\$GPRMC,${timestamp},V,,,,,,${datestamp},,,"
        local rmc_checksum=$(calculate_checksum "$rmc_sentence")
        echo "${rmc_sentence}*${rmc_checksum}"
    fi
}

generate_nmea_gsa() {
    local gsa_sentence
    if [[ "$GPS_VALID" == "true" && "$GPS_SATS" -gt 3 ]]; then

        gsa_sentence="\$GPGSA,A,3,,,,,,,,,,,,,1.0,1.0,1.0"
    else

        gsa_sentence="\$GPGSA,A,1,,,,,,,,,,,,,,,,"
    fi
    local gsa_checksum=$(calculate_checksum "$gsa_sentence")
    echo "${gsa_sentence}*${gsa_checksum}"
}

setup_pipe() {
    if [[ -e "$GPS_PIPE" ]]; then
        rm -f "$GPS_PIPE" 2>/dev/null || true
    fi
    
    if mkfifo "$GPS_PIPE" 2>/dev/null; then
        chmod 666 "$GPS_PIPE" 2>/dev/null || true  
        echo "Created GPS data pipe: $GPS_PIPE"
        echo
        echo "To use with gpsd, run one of these commands:"
        echo "  sudo gpsd -N -D 2 $GPS_PIPE"
        echo "  sudo systemctl stop gpsd && sudo gpsd -N $GPS_PIPE"
        echo
        return 0
    else
        error_exit "Failed to create named pipe $GPS_PIPE"
    fi
}

write_to_pipe() {
    local data="$1"
    
    if [[ ! -p "$GPS_PIPE" ]]; then
        mkfifo "$GPS_PIPE" 2>/dev/null || return 1
        chmod 666 "$GPS_PIPE" 2>/dev/null || true
    fi
    

    if echo "$data" > "$GPS_PIPE" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

cleanup() {
    echo "Cleaning up..."
    if [[ -e "$GPS_PIPE" ]]; then
        rm -f "$GPS_PIPE" 2>/dev/null || true
    fi
    exit 0
}

main() {
    echo "Starlink NMEA Middleman"
    echo "======================="
    
    check_dependencies
    
    trap cleanup EXIT INT TERM
    trap '' PIPE  
    
    setup_pipe
    
    echo "Starting high-speed NMEA data stream from Starlink..."
    echo "Update rate: $(echo "1 / $UPDATE_INTERVAL" | bc -l | cut -d. -f1) Hz"
    echo "Press Ctrl+C to stop"
    echo
    echo "DEBUG: Starting main loop..."
    
    local count=0
    local successful_reads=0
    local failed_reads=0
    local last_status_time=$(date +%s)

    while true; do
        echo "DEBUG: Loop iteration $((count + 1))"
        
        if get_starlink_data; then
            ((successful_reads++))
            echo "DEBUG: Got Starlink data - GPS_VALID=$GPS_VALID"
        else
            ((failed_reads++))
            echo "DEBUG: Failed to get Starlink data"
        fi
        

        local gga_data=$(generate_nmea_gga)
        if [[ -n "$gga_data" ]]; then
            echo "DEBUG: Generated GGA: $gga_data"
            if write_to_pipe "$gga_data"; then
                echo "DEBUG: GGA written successfully"
            else
                echo "DEBUG: GGA write failed (no reader)"
            fi
        fi
        
        sleep 0.05
        
        local rmc_data=$(generate_nmea_rmc)
        if [[ -n "$rmc_data" ]]; then
            echo "DEBUG: Generated RMC: $rmc_data"
            write_to_pipe "$rmc_data" || true
        fi
        
        sleep 0.05
        
        local gsa_data=$(generate_nmea_gsa)
        if [[ -n "$gsa_data" ]]; then
            echo "DEBUG: Generated GSA: $gsa_data"
            write_to_pipe "$gsa_data" || true
        fi
        
        ((count++))
        echo "DEBUG: Completed cycle $count"
        
        local current_time=$(date +%s)
        if (( current_time - last_status_time >= 10 )); then
            local rate=$(echo "scale=1; $count / 10" | bc -l)
            echo "$(date '+%H:%M:%S'): $count cycles sent (${rate}/s) | GPS: Sats=$GPS_SATS Valid=$GPS_VALID | Starlink: OK=$successful_reads Fail=$failed_reads"
            last_status_time=$current_time
            count=0
        fi
        
        echo "DEBUG: Sleeping..."
        sleep 0.1 2>/dev/null || sleep 0.1
        echo "DEBUG: Woke up, continuing loop..."
    done
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 