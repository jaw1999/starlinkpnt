# Starlink PNT (Position, Navigation, Timing) Scripts

This repository contains scripts to interface with Starlink terminals to extract GPS/PNT data and convert it to various formats for use with navigation systems.

## Scripts

### 1. `starlink_to_gpsd.sh`
Converts Starlink PNT data to NMEA format for use with GPSD.

**Features:**
- Connects to Starlink terminal via gRPC
- Generates NMEA sentences (GGA, RMC, GSA)
- Creates a named pipe for GPSD consumption
- High-speed updates (configurable, default 5Hz)

**Usage:**
```bash
./starlink_to_gpsd.sh
```

**To use with GPSD:**
```bash
# Terminal 1: Start the bridge
./starlink_to_gpsd.sh

# Terminal 2: Start GPSD
sudo gpsd -N -D 2 /tmp/starlink_nmea
```

### 2. `starlink_to_mavlink.sh`
Converts Starlink PNT data to MAVLink format for use with drone autopilots and GCS software.

**Features:**
- Connects to Starlink terminal via gRPC
- Generates MAVLink v1 messages (HEARTBEAT, GPS_RAW_INT, GLOBAL_POSITION_INT, GPS_STATUS)
- Sends data via UDP (default: 127.0.0.1:14550)
- High-speed updates (default 10Hz)

**Usage:**
```bash
# Normal mode
./starlink_to_mavlink.sh

# Debug mode (shows detailed message sending info)
DEBUG_MAVLINK=true ./starlink_to_mavlink.sh
```

**Configuration:**
Edit the script to change these parameters:
- `MAVLINK_UDP_IP`: Target IP address (default: 127.0.0.1)
- `MAVLINK_UDP_PORT`: Target UDP port (default: 14550)
- `MAVLINK_SYSTEM_ID`: MAVLink system ID (default: 01)
- `MAVLINK_COMPONENT_ID`: Component ID (default: dc - GPS component)
- `UPDATE_INTERVAL`: Update rate in seconds (default: 0.1 = 10Hz)

**Compatible with:**
- Mission Planner
- QGroundControl
- ArduPilot
- PX4
- Any MAVLink-compatible ground control station

### 3. `starlinkpnt.sh`
Real-time monitoring script that displays Starlink PNT data in a formatted terminal interface with NTP synchronization.

**Features:**
- **Live Position Display**: Real-time GPS coordinates with precision
- **NTP Time Synchronization**: Integrates with Starlink's NTP server for precise timing
- **Navigation Status**: Satellite count, GPS validity, and distance tracking
- **Performance Monitoring**: Update rates, runtime, and reading counts
- **Enhanced Display**: Stable terminal interface with color-coded status indicators
- **Time Accuracy**: Shows NTP offset and synchronization status

**NTP Integration:**
- Connects to Starlink NTP server (192.168.100.1)
- Displays time offset in milliseconds
- Shows synchronization status and last sync time
- Uses NTP-corrected time when available
- Falls back to system time when NTP unavailable

**Display Sections:**
- **POSITION**: Latitude, Longitude, Altitude, Accuracy
- **NAVIGATION**: Satellites, GPS Valid status, Distance moved
- **TIMING**: Current time (NTP or system), Runtime, Update rate
- **NTP SYNCHRONIZATION**: Status, Time offset, Last sync time

**Configuration:**
Edit the script to customize:
- `USE_NTP_DISPLAY`: Enable/disable NTP features (default: `true`)
- `NTP_UPDATE_INTERVAL`: NTP sync frequency (default: `60` seconds)
- `UPDATE_INTERVAL`: Display refresh rate (default: `0.1` = 10Hz)

**Usage:**
```bash
./starlinkpnt.sh
```

**Example Output:**
```
STARLINK PNT MONITOR
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

POSITION
  Latitude:      47.109743°
  Longitude:     -122.569048°
  Altitude:      60.52 m
  Accuracy:      ±25.0 m

NAVIGATION
  Satellites:    12
  GPS Valid:     Yes
  Distance Moved: 0.00 m

TIMING
  Time:          20:28:49 UTC (NTP)
  Runtime:       00:00:05
  Update Rate:   10.0 Hz
  Readings:      14

NTP SYNCHRONIZATION
  NTP Status:    SYNCHRONIZED
  Time Offset:   2 ms
  Last Sync:     13:28:44 (5s ago)
```

### 4. `starlink_nmea_fallback.sh`
Advanced GPS fallback system that monitors a primary GPS device and automatically switches to Starlink when the primary GPS fails.

**Features:**
- **Primary GPS Monitoring**: Continuously monitors a primary GPS device (e.g., `/dev/ttyUSB0`)
- **Automatic Fallback**: Switches to Starlink when primary GPS is:
  - Disconnected or unplugged
  - Loses GPS lock for configured threshold (default: 30 seconds)
  - Shows suspicious position jumps (spoofing/jamming detection)
- **Seamless Recovery**: Automatically switches back to primary GPS when available
- **NTP Time Synchronization**: Uses Starlink NTP server for precise timing during fallback
- **NMEA Output**: Generates standard NMEA sentences (GGA, RMC, GSA) for GPSD consumption
- **Robust Error Handling**: Handles network issues, device disconnections, and pipe errors
- **Comprehensive Logging**: Detailed status reporting and diagnostics

**Configuration:**
Edit the script to customize these parameters:
- `PRIMARY_GPS_DEVICE`: GPS device path (default: `/dev/ttyUSB0`)
- `PRIMARY_GPS_BAUD`: GPS baud rate (default: `9600`)
- `LOCK_LOSS_THRESHOLD`: Seconds without GPS lock before fallback (default: `30`)
- `POSITION_JUMP_THRESHOLD`: Meters for spoofing detection (default: `1000`)
- `RECOVERY_CHECK_INTERVAL`: Seconds between recovery checks (default: `60`)
- `USE_NTP_FALLBACK`: Enable NTP timing during fallback (default: `true`)

**Usage:**
```bash
# Start the fallback system
./starlink_nmea_fallback.sh

# In another terminal, start GPSD
sudo gpsd -N -D 2 -n /tmp/starlink_nmea_fallback
```

**GPSD Configuration:**
Edit `/etc/default/gpsd`:
```bash
START_DAEMON="true"
DEVICES="/tmp/starlink_nmea_fallback"
GPSD_OPTIONS="-n"
USBAUTO="true"
```

**System Integration:**
```bash
# Enable GPSD service
sudo systemctl enable gpsd

# Start GPSD
sudo systemctl start gpsd

# Test GPS data
gpspipe -w | grep TPV
```

**Monitoring:**
The script provides real-time status including:
- Primary GPS health (healthy/failed/disconnected)
- Fallback status (active/inactive)
- GPS position validity and satellite count
- NTP synchronization status
- Update rates and error counts

## Requirements

All scripts require:
- `grpcurl` - For communicating with Starlink terminal
- `bc` - For mathematical calculations
- `bash` - Shell environment

Additional requirements:
- **MAVLink script**: `python3`, `nc` (netcat)
- **GPSD script**: `gpsd` (for consumption)
- **Fallback script**: `gpsd`, `stty`, `timeout`, `ntpdate` (for NTP sync)

### Installing Dependencies

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install grpcurl bc netcat-openbsd python3
```

**For GPSD:**
```bash
sudo apt install gpsd gpsd-clients
```

**For Fallback Script:**
```bash
sudo apt install gpsd gpsd-clients ntpdate
```

## Starlink Terminal Setup

1. Ensure your Starlink terminal is connected and operational
2. Make sure you can reach the terminal at `192.168.100.1`
3. The gRPC interface should be available on port `9200`

## Network Configuration

The scripts assume the standard Starlink network configuration:
- Starlink terminal IP: `192.168.100.1`
- gRPC port: `9200`

If your setup is different, edit the `STARLINK_IP` and `STARLINK_PORT` variables in the scripts.

## Troubleshooting

### Common Issues

1. **Cannot connect to Starlink terminal**
   - Check network connectivity: `ping 192.168.100.1`
   - Verify gRPC port is accessible: `nc -zv 192.168.100.1 9200`

2. **grpcurl not found**
   - Install grpcurl following the instructions above

3. **GPSD not receiving data**
   - Check that the named pipe exists: `ls -la /tmp/starlink_nmea*`
   - Verify GPSD is reading from the correct device
   - For fallback script: Check `/etc/default/gpsd` configuration

4. **Fallback script not working**
   - Verify primary GPS device exists: `ls -la /dev/ttyUSB*`
   - Check Starlink connectivity: `nc -zv 192.168.100.1 9200`
   - Monitor script output for error messages
   - Test pipe communication: `timeout 3 cat /tmp/starlink_nmea_fallback`
   - Check GPSD status: `systemctl status gpsd`

5. **MAVLink data not received**
   - Check UDP port is not blocked by firewall
   - Verify ground control station is listening on the correct port
   - Use `tcpdump` to monitor UDP traffic: `sudo tcpdump -i lo udp port 14550`

### Testing MAVLink Output

To test the MAVLink output without a ground control station:
```bash
# Listen on UDP port to see raw MAVLink data
nc -ul 14550 | hexdump -C
```

## Data Format Examples

### NMEA (GPSD script)
```
$GPGGA,123456,4807.038,N,01131.000,E,1,04,1.0,545.4,M,46.9,M,,*47
$GPRMC,123456,A,4807.038,N,01131.000,E,0.0,0.0,230394,,,*1E
$GPGSA,A,3,,,,,,,,,,,,,1.0,1.0,1.0*30
```

### MAVLink Messages (MAVLink script)
- HEARTBEAT (ID 0): System status
- GPS_RAW_INT (ID 24): Raw GPS data with accuracy
- GLOBAL_POSITION_INT (ID 33): Position in global coordinates
- GPS_STATUS (ID 25): Satellite information

