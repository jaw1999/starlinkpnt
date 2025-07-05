#!/bin/bash

set +e 
set +u  

# =============================================================================
# Starlink NMEA Fallback System
# =============================================================================
# This script monitors a primary NMEA GPS device and falls back to Starlink
# API calls when the primary GPS fails (unplugged, loses lock, or spoofing detected)
# =============================================================================

# Starlink Configuration
readonly STARLINK_IP="192.168.100.1"
readonly STARLINK_PORT="9200"

# Primary GPS Configuration
readonly PRIMARY_GPS_DEVICE="/dev/ttyUSB0"  # Adjust to your GPS device
readonly PRIMARY_GPS_BAUD="9600"            # Adjust to your GPS baud rate
readonly PRIMARY_GPS_TIMEOUT="5"            # Timeout for reading from GPS device

# Failover Configuration
readonly LOCK_LOSS_THRESHOLD="30"           # Seconds without valid GPS lock before fallback
readonly POSITION_JUMP_THRESHOLD="1000"     # Meters - suspicious position jump (spoofing detection)
readonly RECOVERY_CHECK_INTERVAL="60"       # Seconds between primary GPS recovery checks
readonly UPDATE_INTERVAL=0.2                # NMEA output update rate

# Output Configuration
readonly GPS_PIPE="/tmp/starlink_nmea_fallback"

# NTP Configuration
readonly NTP_SERVER="192.168.100.1"             # Starlink NTP server
readonly NTP_TIMEOUT="3"                        # NTP query timeout
readonly NTP_UPDATE_INTERVAL="60"               # Seconds between NTP sync updates
readonly USE_NTP_FALLBACK="true"                # Use NTP timing when in Starlink fallback mode

# Global State Variables
LAT=""
LON=""
ALT=""
ACCURACY=""
GPS_SATS="0"
GPS_VALID="false"
PRIMARY_GPS_STATE="unknown"  # unknown, healthy, failed, disconnected
FALLBACK_ACTIVE="false"
LAST_VALID_TIME=""
LAST_VALID_LAT=""
LAST_VALID_LON=""
NTP_OFFSET="0"                                  # NTP time offset in seconds
NTP_LAST_SYNC=""                               # Last NTP sync timestamp
NTP_AVAILABLE="false"                          # NTP server availability status

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
    
    if ! command_exists stty; then
        missing_deps+=("stty")
    fi
    
    if ! command_exists timeout; then
        missing_deps+=("timeout")
    fi
    
    if ! command_exists ntpdate; then
        missing_deps+=("ntpdate")
    fi
    
    if ! command_exists nc; then
        missing_deps+=("nc")
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
    

    # Check connectivity first
    if ! timeout 2 nc -z "${STARLINK_IP}" "${STARLINK_PORT}" 2>/dev/null; then
        echo "DEBUG: Cannot connect to ${STARLINK_IP}:${STARLINK_PORT}"
        return 1
    fi
    
    # Query location and status
    if location_json=$(timeout 3 grpcurl -plaintext -d '{"get_location":{}}' \
        "${STARLINK_IP}:${STARLINK_PORT}" \
        SpaceX.API.Device.Device/Handle 2>/dev/null); then
        
        if status_json=$(timeout 3 grpcurl -plaintext -d '{"get_status":{}}' \
            "${STARLINK_IP}:${STARLINK_PORT}" \
            SpaceX.API.Device.Device/Handle 2>/dev/null); then
            
            if [[ -n "$location_json" && -n "$status_json" ]]; then

                LAT=$(echo "$location_json" | grep -oP '"lat":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                LON=$(echo "$location_json" | grep -oP '"lon":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                ALT=$(echo "$location_json" | grep -oP '"alt":\s*\K[-0-9.]+' 2>/dev/null || echo "")
                ACCURACY=$(echo "$location_json" | grep -oP '"sigmaM":\s*\K[0-9.]+' 2>/dev/null || echo "")
                

                GPS_SATS=$(echo "$status_json" | grep -oP '"gpsSats":\s*\K[0-9]+' 2>/dev/null || echo "0")
                GPS_VALID=$(echo "$status_json" | grep -oP '"gpsValid":\s*\K(true|false)' 2>/dev/null || echo "false")
                
                echo "DEBUG: Got Starlink data - LAT=$LAT, LON=$LON, GPS_VALID=$GPS_VALID, SATS=$GPS_SATS"
                return 0
            else
                echo "DEBUG: Empty JSON responses from Starlink"
            fi
        else
            echo "DEBUG: Status query failed"
        fi
    else
        echo "DEBUG: Location query failed"
    fi
    

    return 1
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
    
    # Use awk for more reliable floating point math
    if [[ "$is_longitude" == "true" ]]; then
        echo "$decimal" | awk '{
            decimal = $1
            abs_decimal = (decimal < 0) ? -decimal : decimal
            degrees = int(abs_decimal)
            minutes_decimal = (abs_decimal - degrees) * 60
            hemisphere = (decimal >= 0) ? "E" : "W"
            printf "%03d%07.4f,%s", degrees, minutes_decimal, hemisphere
        }'
    else
        echo "$decimal" | awk '{
            decimal = $1
            abs_decimal = (decimal < 0) ? -decimal : decimal
            degrees = int(abs_decimal)
            minutes_decimal = (abs_decimal - degrees) * 60
            hemisphere = (decimal >= 0) ? "N" : "S"
            printf "%02d%07.4f,%s", degrees, minutes_decimal, hemisphere
        }'
    fi
}

generate_nmea_gga() {
    local use_ntp_timing="${1:-false}"  # Use NTP timing when true
    local timestamp
    
    if [[ "$use_ntp_timing" == "true" ]]; then
        timestamp=$(get_ntp_timestamp "time" "true")
    else
        timestamp=$(date -u '+%H%M%S' 2>/dev/null || echo "000000")
    fi
    
    if [[ "$GPS_VALID" == "true" && -n "$LAT" && -n "$LON" && "$LAT" != "0" && "$LON" != "0" ]]; then
        local lat_dms lon_dms quality hdop
        lat_dms=$(convert_to_dms "$LAT" "false")
        lon_dms=$(convert_to_dms "$LON" "true")
        
        quality="1"
        # Ensure HDOP is never empty
        if [[ -n "$ACCURACY" && "$ACCURACY" != "0" ]]; then
            hdop=$(echo "scale=1; $ACCURACY / 5" | bc -l 2>/dev/null || echo "1.0")
        else
            hdop="1.0"
        fi
        
        # Format altitude to match original script behavior
        local alt_formatted="${ALT:-0.0}"
        
        local gga_sentence="\$GPGGA,${timestamp},${lat_dms},${lon_dms},${quality},${GPS_SATS},${hdop},${alt_formatted},M,0.0,M,,"
        local gga_checksum=$(calculate_checksum "$gga_sentence")
        echo "${gga_sentence}*${gga_checksum}"
    else
        local gga_sentence="\$GPGGA,${timestamp},,,,0,0,,0.0,M,0.0,M,,"
        local gga_checksum=$(calculate_checksum "$gga_sentence")
        echo "${gga_sentence}*${gga_checksum}"
    fi
}

generate_nmea_rmc() {
    local use_ntp_timing="${1:-false}"  # Use NTP timing when true
    local timestamp datestamp
    
    if [[ "$use_ntp_timing" == "true" ]]; then
        local datetime_result
        datetime_result=$(get_ntp_timestamp "datetime" "true")
        timestamp=$(echo "$datetime_result" | cut -d' ' -f1)
        datestamp=$(echo "$datetime_result" | cut -d' ' -f2)
    else
        timestamp=$(date -u '+%H%M%S' 2>/dev/null || echo "000000")
        datestamp=$(date -u '+%d%m%y' 2>/dev/null || echo "010100")
    fi
    
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
    local use_ntp_timing="${1:-false}"  # Parameter for consistency, though GSA doesn't use timestamps
    local gsa_sentence
    
    if [[ "$GPS_VALID" == "true" && "$GPS_SATS" -gt 3 ]]; then
        # Simple GSA with first 8 satellite PRNs (common approach)
        gsa_sentence="\$GPGSA,A,3,01,02,03,04,05,06,07,08,,,,,1.0,1.0,1.0"
    else
        gsa_sentence="\$GPGSA,A,1,,,,,,,,,,,,,,,,"
    fi
    local gsa_checksum=$(calculate_checksum "$gsa_sentence")
    echo "${gsa_sentence}*${gsa_checksum}"
}

setup_pipe() {
    echo "Setting up GPS fallback pipe..."
    
    if [[ -e "$GPS_PIPE" ]]; then
        if [[ -p "$GPS_PIPE" ]]; then
            echo "Named pipe already exists at: $GPS_PIPE"
        else
            echo "File exists but is not a pipe. Removing and recreating..."
            rm -f "$GPS_PIPE" 2>/dev/null || {
                error_exit "Failed to remove existing file at $GPS_PIPE"
            }
            mkfifo "$GPS_PIPE" 2>/dev/null || {
                error_exit "Failed to create named pipe $GPS_PIPE"
            }
        fi
    else
        echo "Creating named pipe at: $GPS_PIPE"
        mkfifo "$GPS_PIPE" 2>/dev/null || {
            error_exit "Failed to create named pipe $GPS_PIPE"
        }
    fi
    
    # Set proper permissions
    chmod 666 "$GPS_PIPE" 2>/dev/null || {
        warn "Failed to set permissions on $GPS_PIPE"
    }
    
    # Verify the pipe was created correctly
    if [[ -p "$GPS_PIPE" ]]; then
        echo "✓ GPS fallback pipe created successfully: $GPS_PIPE"
        ls -la "$GPS_PIPE"
    else
        error_exit "Failed to verify named pipe creation"
    fi
    
    echo
    echo "To use with gpsd, run one of these commands:"
    echo "  sudo gpsd -N -D 2 -n $GPS_PIPE   (debug mode)"
    echo "  sudo gpsd -N -n $GPS_PIPE         (normal mode)"
    echo
    echo "Note: The -n flag tells gpsd to immediately start polling the GPS"
    echo "      Without -n, gpsd waits for a client to connect before reading"
    echo
}

write_to_pipe() {
    local data="$1"
    
    if [[ ! -p "$GPS_PIPE" ]]; then
        mkfifo "$GPS_PIPE" 2>/dev/null || return 1
        chmod 666 "$GPS_PIPE" 2>/dev/null || true
    fi
    
    # Non-blocking write with proper NMEA line endings (CR/LF)
    # Using timeout to prevent blocking if no reader is present
    # Write directly to avoid variable expansion issues
    {
        timeout 0.1 bash -c "printf '%s\r\n' \"\$1\"" _ "$data" > "$GPS_PIPE"
    } 2>/dev/null && return 0 || return 1
}

cleanup() {
    echo "Cleaning up..."
    if [[ -e "$GPS_PIPE" ]]; then
        rm -f "$GPS_PIPE" 2>/dev/null || true
    fi
    exit 0
}

# =============================================================================
# NTP Functions
# =============================================================================

check_ntp_server() {
    if timeout "$NTP_TIMEOUT" nc -u -z "$NTP_SERVER" 123 2>/dev/null; then
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
        warn "NTP server $NTP_SERVER is not available"
        return 1
    fi
    
    # Query NTP server
    if ntp_result=$(timeout "$NTP_TIMEOUT" ntpdate -q "$NTP_SERVER" 2>/dev/null); then
        # Parse ntpdate output: "server 192.168.100.1, stratum 1, offset +0.004257, delay 0.02939"
        local offset_line
        if offset_line=$(echo "$ntp_result" | grep "offset"); then
            local offset
            if offset=$(echo "$offset_line" | grep -oP 'offset\s+[+-]?\K[0-9.-]+' | tr -d '\n'); then
                NTP_OFFSET="$offset"
                NTP_LAST_SYNC="$current_time"
                NTP_AVAILABLE="true"
                echo "NTP sync successful: offset=${offset}s"
                return 0
            fi
        fi
    fi
    
    NTP_AVAILABLE="false"
    warn "Failed to sync with NTP server $NTP_SERVER"
    return 1
}

get_ntp_timestamp() {
    local format="$1"  # Format: "time" for HHMMSS, "date" for DDMMYY, "datetime" for both
    local use_ntp="$2" # "true" to use NTP time, "false" for system time
    
    if [[ "$use_ntp" == "true" && "$NTP_AVAILABLE" == "true" ]]; then
        # Calculate NTP-corrected time
        local current_epoch=$(date +%s)
        local ntp_epoch=$(echo "scale=3; $current_epoch + $NTP_OFFSET" | bc -l 2>/dev/null || echo "$current_epoch")
        
        case "$format" in
            "time")
                date -u -d "@$ntp_epoch" '+%H%M%S' 2>/dev/null || date -u '+%H%M%S'
                ;;
            "date")
                date -u -d "@$ntp_epoch" '+%d%m%y' 2>/dev/null || date -u '+%d%m%y'
                ;;
            "datetime")
                local time_part=$(date -u -d "@$ntp_epoch" '+%H%M%S' 2>/dev/null || date -u '+%H%M%S')
                local date_part=$(date -u -d "@$ntp_epoch" '+%d%m%y' 2>/dev/null || date -u '+%d%m%y')
                echo "${time_part} ${date_part}"
                ;;
            *)
                date -u -d "@$ntp_epoch" '+%H%M%S' 2>/dev/null || date -u '+%H%M%S'
                ;;
        esac
    else
        # Use system time
        case "$format" in
            "time")
                date -u '+%H%M%S'
                ;;
            "date")
                date -u '+%d%m%y'
                ;;
            "datetime")
                local time_part=$(date -u '+%H%M%S')
                local date_part=$(date -u '+%d%m%y')
                echo "${time_part} ${date_part}"
                ;;
            *)
                date -u '+%H%M%S'
                ;;
        esac
    fi
}

# =============================================================================
# Primary GPS Functions
# =============================================================================

check_primary_gps_device() {
    if [[ -c "$PRIMARY_GPS_DEVICE" ]]; then
        return 0
    else
        return 1
    fi
}

setup_primary_gps() {
    if check_primary_gps_device; then
        if stty -F "$PRIMARY_GPS_DEVICE" "$PRIMARY_GPS_BAUD" raw -echo 2>/dev/null; then
            echo "Primary GPS device configured: $PRIMARY_GPS_DEVICE at $PRIMARY_GPS_BAUD baud"
            return 0
        else
            warn "Failed to configure primary GPS device"
            return 1
        fi
    else
        warn "Primary GPS device not found: $PRIMARY_GPS_DEVICE"
        return 1
    fi
}

read_primary_gps() {
    local nmea_sentence=""
    
    if ! check_primary_gps_device; then
        PRIMARY_GPS_STATE="disconnected"
        return 1
    fi
    
    # Read NMEA sentence with timeout
    if nmea_sentence=$(timeout "$PRIMARY_GPS_TIMEOUT" cat "$PRIMARY_GPS_DEVICE" 2>/dev/null | head -n 1); then
        if [[ -n "$nmea_sentence" && "$nmea_sentence" =~ ^\$GP ]]; then
            echo "$nmea_sentence"
            return 0
        fi
    fi
    
    return 1
}

parse_nmea_sentence() {
    local sentence="$1"
    
    # Reset GPS state
    LAT=""
    LON=""
    ALT=""
    ACCURACY=""
    GPS_SATS="0"
    GPS_VALID="false"
    
    # Parse GGA sentence (Global Positioning System Fix Data)
    if [[ "$sentence" =~ ^\$GPGGA ]]; then
        IFS=',' read -ra FIELDS <<< "$sentence"
        
        if [[ ${#FIELDS[@]} -ge 15 ]]; then
            local lat_raw="${FIELDS[2]}"
            local lat_ns="${FIELDS[3]}"
            local lon_raw="${FIELDS[4]}"
            local lon_ew="${FIELDS[5]}"
            local quality="${FIELDS[6]}"
            local satellites="${FIELDS[7]}"
            local hdop="${FIELDS[8]}"
            local altitude="${FIELDS[9]}"
            
            # Convert to decimal degrees
            if [[ -n "$lat_raw" && -n "$lon_raw" && "$quality" -gt 0 ]]; then
                LAT=$(convert_dms_to_decimal "$lat_raw" "$lat_ns")
                LON=$(convert_dms_to_decimal "$lon_raw" "$lon_ew")
                ALT="$altitude"
                GPS_SATS="$satellites"
                GPS_VALID="true"
                ACCURACY=$(echo "scale=1; $hdop * 5" | bc -l 2>/dev/null || echo "10.0")
                return 0
            fi
        fi
    fi
    
    return 1
}

convert_dms_to_decimal() {
    local dms="$1"
    local hemisphere="$2"
    
    if [[ -z "$dms" ]]; then
        echo "0.0"
        return
    fi
    
    # Extract degrees and minutes from DDMM.MMMM or DDDMM.MMMM format
    local degrees minutes decimal_degrees
    
    if [[ ${#dms} -eq 9 ]]; then  # DDMM.MMMM (latitude)
        degrees="${dms:0:2}"
        minutes="${dms:2}"
    elif [[ ${#dms} -eq 10 ]]; then  # DDDMM.MMMM (longitude)
        degrees="${dms:0:3}"
        minutes="${dms:3}"
    else
        echo "0.0"
        return
    fi
    
    decimal_degrees=$(echo "scale=8; $degrees + $minutes / 60" | bc -l 2>/dev/null || echo "0.0")
    
    # Apply hemisphere
    if [[ "$hemisphere" == "S" || "$hemisphere" == "W" ]]; then
        decimal_degrees=$(echo "scale=8; -1 * $decimal_degrees" | bc -l 2>/dev/null || echo "0.0")
    fi
    
    echo "$decimal_degrees"
}

detect_spoofing() {
    local current_lat="$1"
    local current_lon="$2"
    
    if [[ -z "$LAST_VALID_LAT" || -z "$LAST_VALID_LON" ]]; then
        # First valid position, store it
        LAST_VALID_LAT="$current_lat"
        LAST_VALID_LON="$current_lon"
        return 0
    fi
    
    # Calculate distance between last and current position
    local distance
    distance=$(calculate_distance "$LAST_VALID_LAT" "$LAST_VALID_LON" "$current_lat" "$current_lon")
    
    if (( $(echo "$distance > $POSITION_JUMP_THRESHOLD" | bc -l) )); then
        warn "Suspicious position jump detected: ${distance}m (threshold: ${POSITION_JUMP_THRESHOLD}m)"
        return 1
    fi
    
    # Update last valid position
    LAST_VALID_LAT="$current_lat"
    LAST_VALID_LON="$current_lon"
    return 0
}

calculate_distance() {
    local lat1="$1" lon1="$2" lat2="$3" lon2="$4"
    
    # Haversine formula for distance calculation
    local dlat dlon a c distance
    dlat=$(echo "scale=8; ($lat2 - $lat1) * 3.14159265359 / 180" | bc -l)
    dlon=$(echo "scale=8; ($lon2 - $lon1) * 3.14159265359 / 180" | bc -l)
    lat1=$(echo "scale=8; $lat1 * 3.14159265359 / 180" | bc -l)
    lat2=$(echo "scale=8; $lat2 * 3.14159265359 / 180" | bc -l)
    
    a=$(echo "scale=8; s($dlat/2)^2 + c($lat1) * c($lat2) * s($dlon/2)^2" | bc -l)
    c=$(echo "scale=8; 2 * a(sqrt($a)/sqrt(1-$a))" | bc -l)
    distance=$(echo "scale=1; 6371000 * $c" | bc -l)  # Earth radius in meters
    
    echo "$distance"
}

check_primary_gps_health() {
    local nmea_sentence
    
    if ! check_primary_gps_device; then
        PRIMARY_GPS_STATE="disconnected"
        return 1
    fi
    
    if nmea_sentence=$(read_primary_gps); then
        if parse_nmea_sentence "$nmea_sentence"; then
            if [[ "$GPS_VALID" == "true" ]]; then
                if detect_spoofing "$LAT" "$LON"; then
                    PRIMARY_GPS_STATE="healthy"
                    LAST_VALID_TIME=$(date +%s)
                    return 0
                else
                    PRIMARY_GPS_STATE="failed"
                    warn "Primary GPS: Spoofing/jamming detected"
                    return 1
                fi
            else
                PRIMARY_GPS_STATE="failed"
                return 1
            fi
        else
            PRIMARY_GPS_STATE="failed"
            return 1
        fi
    else
        PRIMARY_GPS_STATE="failed"
        return 1
    fi
}

should_fallback_to_starlink() {
    local current_time=$(date +%s)
    
    case "$PRIMARY_GPS_STATE" in
        "disconnected")
            return 0
            ;;
        "failed")
            if [[ -n "$LAST_VALID_TIME" ]]; then
                local time_since_valid=$((current_time - LAST_VALID_TIME))
                if (( time_since_valid > LOCK_LOSS_THRESHOLD )); then
                    return 0
                fi
            else
                return 0
            fi
            ;;
        "healthy")
            return 1
            ;;
        *)
            return 1
            ;;
    esac
    
    return 1
}

main() {
    echo "Starlink NMEA Fallback System"
    echo "============================="
    echo "Primary GPS: $PRIMARY_GPS_DEVICE"
    echo "Fallback: Starlink API ($STARLINK_IP:$STARLINK_PORT)"
    echo "NTP Server: $NTP_SERVER (for enhanced timing)"
    echo "Lock loss threshold: ${LOCK_LOSS_THRESHOLD}s"
    echo "Position jump threshold: ${POSITION_JUMP_THRESHOLD}m"
    echo
    
    check_dependencies
    
    trap cleanup EXIT INT TERM
    trap '' PIPE  
    
    setup_pipe
    
    # Try to setup primary GPS
    if setup_primary_gps; then
        echo "Primary GPS initialized successfully"
    else
        echo "Primary GPS initialization failed - will attempt Starlink fallback"
    fi
    
    # Initialize NTP synchronization if enabled
    if [[ "$USE_NTP_FALLBACK" == "true" ]]; then
        echo "Initializing NTP synchronization with $NTP_SERVER..."
        if sync_ntp_time; then
            echo "NTP synchronization initialized successfully"
        else
            echo "NTP synchronization failed - will use system time"
        fi
    else
        echo "NTP synchronization disabled"
    fi
    
    echo
    echo "Starting GPS monitoring and fallback system..."
    echo "Press Ctrl+C to stop"
    echo
    echo "IMPORTANT: Start gpsd with one of these commands:"
    echo "  sudo gpsd -N -D 2 -n $GPS_PIPE   (debug mode)"
    echo "  sudo gpsd -N -n $GPS_PIPE         (normal mode)"
    echo
    
    local count=0
    local primary_healthy_count=0
    local fallback_count=0
    local last_status_time=$(date +%s)
    local last_recovery_check=$(date +%s)
    local last_ntp_sync=$(date +%s)
    local pipe_error_count=0
    
    while true; do
        local current_time=$(date +%s)
        
        # Periodic NTP synchronization when using fallback
        if [[ "$USE_NTP_FALLBACK" == "true" && "$FALLBACK_ACTIVE" == "true" ]] && 
           (( current_time - last_ntp_sync >= NTP_UPDATE_INTERVAL )); then
            sync_ntp_time
            last_ntp_sync=$current_time
        fi
        
        # Check if we should test primary GPS recovery (when in fallback mode)
        if [[ "$FALLBACK_ACTIVE" == "true" ]] && (( current_time - last_recovery_check >= RECOVERY_CHECK_INTERVAL )); then
            echo "Checking primary GPS recovery..."
            last_recovery_check=$current_time
        fi
        
        # Check primary GPS health
        if check_primary_gps_health; then
            # Primary GPS is healthy
            if [[ "$FALLBACK_ACTIVE" == "true" ]]; then
                echo "Primary GPS recovered! Switching back from Starlink fallback"
                FALLBACK_ACTIVE="false"
                pipe_error_count=0  # Reset pipe error count
            fi
            
            ((primary_healthy_count++))
            
            # Read NMEA sentence from primary GPS and pass it through
            local nmea_sentence
            if nmea_sentence=$(read_primary_gps); then
                if [[ -n "$nmea_sentence" ]]; then
                    if write_to_pipe "$nmea_sentence"; then
                        echo "PRIMARY: $nmea_sentence"
                        pipe_error_count=0  # Reset error count on success
                    else
                        echo "PRIMARY: $nmea_sentence (no reader)"
                        ((pipe_error_count++))
                    fi
                fi
            fi
            
        elif should_fallback_to_starlink; then
            # Primary GPS failed, activate Starlink fallback
            if [[ "$FALLBACK_ACTIVE" == "false" ]]; then
                case "$PRIMARY_GPS_STATE" in
                    "disconnected")
                        echo "Primary GPS disconnected - activating Starlink fallback"
                        ;;
                    "failed")
                        if [[ -n "$LAST_VALID_TIME" ]]; then
                            local time_since_valid=$((current_time - LAST_VALID_TIME))
                            echo "Primary GPS lock lost for ${time_since_valid}s (threshold: ${LOCK_LOSS_THRESHOLD}s) - activating Starlink fallback"
                        else
                            echo "Primary GPS never achieved lock - activating Starlink fallback"
                        fi
                        ;;
                esac
                FALLBACK_ACTIVE="true"
                pipe_error_count=0  # Reset pipe error count
            fi
            
            ((fallback_count++))
            
            # Get data from Starlink and generate NMEA
            if get_starlink_data; then
                # Generate and send NMEA sentences with proper spacing
                local gga_data=$(generate_nmea_gga "true")
                if [[ -n "$gga_data" ]]; then
                    if write_to_pipe "$gga_data"; then
                        echo "FALLBACK: $gga_data"
                        pipe_error_count=0  # Reset error count on success
                    else
                        echo "FALLBACK: $gga_data (no reader)"
                        ((pipe_error_count++))
                    fi
                fi
                
                sleep 0.05
                
                local rmc_data=$(generate_nmea_rmc "true")
                if [[ -n "$rmc_data" ]]; then
                    if write_to_pipe "$rmc_data"; then
                        echo "FALLBACK: $rmc_data"
                    else
                        echo "FALLBACK: $rmc_data (no reader)"
                        ((pipe_error_count++))
                    fi
                fi
                
                sleep 0.05
                
                local gsa_data=$(generate_nmea_gsa "true")
                if [[ -n "$gsa_data" ]]; then
                    if write_to_pipe "$gsa_data"; then
                        echo "FALLBACK: $gsa_data"
                    else
                        echo "FALLBACK: $gsa_data (no reader)"
                        ((pipe_error_count++))
                    fi
                fi
                
            else
                echo "FALLBACK: Failed to get Starlink data"
                # Send invalid NMEA to indicate no fix
                local invalid_gga=$(generate_nmea_gga "true")
                if write_to_pipe "$invalid_gga"; then
                    echo "FALLBACK: $invalid_gga (no fix)"
                else
                    echo "FALLBACK: $invalid_gga (no reader)"
                    ((pipe_error_count++))
                fi
            fi
        else
            # Primary GPS is not healthy but not yet ready for fallback
            local time_since_valid=""
            if [[ -n "$LAST_VALID_TIME" ]]; then
                time_since_valid=$((current_time - LAST_VALID_TIME))
            fi
            
            echo "PRIMARY: State=$PRIMARY_GPS_STATE, Time since valid: ${time_since_valid}s"
            
            # Send invalid NMEA to indicate no fix
            local invalid_gga=$(generate_nmea_gga "false")  # Use system time, not NTP
            if write_to_pipe "$invalid_gga"; then
                pipe_error_count=0  # Reset error count on success
            else
                ((pipe_error_count++))
            fi
        fi
        
        ((count++))
        
        # Warn about pipe issues if many consecutive errors
        if (( pipe_error_count > 20 )); then
            echo "WARNING: Many pipe write failures. Is gpsd running? Use: sudo gpsd -N -n $GPS_PIPE"
            pipe_error_count=0  # Reset to avoid spam
        fi
        
        # Status reporting
        if (( current_time - last_status_time >= 10 )); then
            local rate=$(echo "scale=1; $count / 10" | bc -l)
            local status_msg="$(date '+%H:%M:%S'): $count cycles (${rate}/s)"
            status_msg="$status_msg | Primary: $PRIMARY_GPS_STATE ($primary_healthy_count healthy)"
            status_msg="$status_msg | Fallback: "
            if [[ "$FALLBACK_ACTIVE" == "true" ]]; then
                status_msg="${status_msg}ACTIVE ($fallback_count cycles)"
            else
                status_msg="${status_msg}INACTIVE"
            fi
            
            # Add NTP status
            if [[ "$USE_NTP_FALLBACK" == "true" ]]; then
                status_msg="$status_msg | NTP: "
                if [[ "$NTP_AVAILABLE" == "true" ]]; then
                    local ntp_offset_ms
                    ntp_offset_ms=$(echo "scale=0; $NTP_OFFSET * 1000" | bc -l 2>/dev/null || echo "0")
                    # Clean up the result and ensure it's not empty
                    ntp_offset_ms=$(echo "$ntp_offset_ms" | tr -d '\n' | sed 's/^$/0/')
                    status_msg="${status_msg}OK (${ntp_offset_ms}ms)"
                    if [[ "$FALLBACK_ACTIVE" == "true" ]]; then
                        status_msg="${status_msg} [ACTIVE]"
                    fi
                else
                    status_msg="${status_msg}FAILED"
                fi
            fi
            
            if [[ "$GPS_VALID" == "true" ]]; then
                status_msg="$status_msg | GPS: Valid, Sats=$GPS_SATS"
            else
                status_msg="$status_msg | GPS: Invalid"
            fi
            
            echo "$status_msg"
            
            last_status_time=$current_time
            count=0
            primary_healthy_count=0
            fallback_count=0
        fi
        
        sleep "$UPDATE_INTERVAL" 2>/dev/null || sleep 0.2
    done
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 