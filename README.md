# Starlink PNT (Position, Navigation, Timing) System

A comprehensive collection of scripts for interfacing with Starlink terminals to extract GPS/PNT data and convert it to various formats for use with navigation systems, including a robust GPS/Starlink fallback system.

## Overview

This repository contains multiple scripts for different use cases:

1. **`starlink_nmea_fallback.py`** - Advanced GPS/Starlink fallback system (main script)
2. **`starlinkpnt.sh`** - Real-time Starlink PNT monitoring with NTP sync
3. **`starlink_to_gpsd.sh`** - Convert Starlink PNT to NMEA for GPSD
4. **`starlink_to_mavlink.sh`** - Convert Starlink PNT to MAVLink for drones/GCS

## Scripts Overview

### 🛰️ **Primary Script: `starlink_nmea_fallback.py`**
A robust GPS/Starlink positioning system that provides continuous NMEA data to gpsd with automatic fallback to Starlink when GPS signal is lost.

**Key Features:**
- **Dual Positioning Sources**: USB u-blox GPS + Starlink fallback
- **Automatic Failover**: Seamless switching between GPS and Starlink
- **Precise Timing**: NTP synchronization with Starlink's time server
- **Comprehensive NMEA Output**: Complete sentence set in fallback mode
- **High-Performance**: Fast updates and quick recovery

### 📊 **Real-time Monitor: `starlinkpnt.sh`**
Real-time monitoring script that displays Starlink PNT data in a formatted terminal interface with NTP synchronization.

**Features:**
- **Live Position Display**: Real-time GPS coordinates with precision
- **NTP Time Synchronization**: Integrates with Starlink's NTP server
- **Navigation Status**: Satellite count, GPS validity, distance tracking
- **Performance Monitoring**: Update rates, runtime, and reading counts
- **Enhanced Display**: Stable terminal interface with color-coded status

### 🔄 **GPSD Bridge: `starlink_to_gpsd.sh`**
Converts Starlink PNT data to NMEA format for use with GPSD.

**Features:**
- **gRPC Connection**: Connects to Starlink terminal via gRPC
- **NMEA Generation**: Creates GGA, RMC, GSA sentences
- **Named Pipe**: Creates pipe for GPSD consumption
- **High-Speed Updates**: Configurable update rate (default 5Hz)

### 🚁 **MAVLink Bridge: `starlink_to_mavlink.sh`**
Converts Starlink PNT data to MAVLink format for use with drone autopilots and GCS software.

**Features:**
- **MAVLink v1 Messages**: HEARTBEAT, GPS_RAW_INT, GLOBAL_POSITION_INT, GPS_STATUS
- **UDP Output**: Sends data via UDP (default: 127.0.0.1:14550)
- **High-Speed Updates**: Default 10Hz update rate
- **Compatible**: Works with Mission Planner, QGroundControl, ArduPilot, PX4

## Features

### 🛰️ **Dual Positioning Sources**
- **Primary**: USB u-blox GPS receiver (NMEA + UBX protocols)
- **Fallback**: Starlink positioning and timing services

### ⚡ **Automatic Failover**
- Seamless switching between GPS and Starlink
- Configurable lock loss threshold (default: 120 seconds)
- Automatic recovery when GPS signal returns

### 🕐 **Precise Timing**
- NTP synchronization with Starlink's time server (192.168.100.1)
- NTP-corrected timestamps in fallback NMEA sentences
- Automatic time offset calculation and application

### 📡 **Comprehensive NMEA Output**
- **GPS Mode**: Pass-through of all NMEA sentences from u-blox GPS
- **Fallback Mode**: Complete NMEA sentence set including:
  - `$GPGGA` - Global Positioning System Fix Data
  - `$GPRMC` - Recommended Minimum Navigation Information
  - `$GPVTG` - Track Made Good and Ground Speed
  - `$GPGLL` - Geographic Position - Latitude/Longitude
  - `$GPGSA` - GNSS DOP and Active Satellites

### 🔄 **High-Performance Operation**
- Fast fallback updates (0.5-second intervals)
- Quick GPS reconnection attempts (1-second intervals)
- Efficient pipe-based communication with gpsd

## Hardware Requirements

- **GPS Receiver**: USB u-blox GPS (tested with u-blox 7 series) - *for fallback system*
- **Starlink**: Active Starlink internet service
- **System**: Linux with Python 3.6+ and gpsd
- **Network**: Access to Starlink terminal at 192.168.100.1

## Software Dependencies

```bash
# Core dependencies
sudo apt-get install python3 python3-pip gpsd gpsd-clients

# Python packages
pip3 install pyserial

# Optional: NTP tools for enhanced timing
sudo apt-get install ntpdate netcat

# For MAVLink script
sudo apt-get install python3 nc

## Installation

1. **Clone or download** the script to your system
2. **Install dependencies** (see above)
3. **Configure** the script for your setup (see Configuration section)
4. **Test** the system (see Testing section)

## Starlink Terminal Setup

### Network Configuration

The scripts assume the standard Starlink network configuration:
- **Starlink terminal IP**: `192.168.100.1`
- **gRPC port**: `9200`
- **NTP server**: `192.168.100.1:123`

If your setup is different, edit the `STARLINK_IP` and `STARLINK_PORT` variables in the scripts.

### Terminal Setup

1. Ensure your Starlink terminal is connected and operational
2. Make sure you can reach the terminal at `192.168.100.1`
3. The gRPC interface should be available on port `9200`

**Test connectivity:**
```bash
# Test basic connectivity
ping 192.168.100.1

# Test gRPC port
nc -zv 192.168.100.1 9200

# Test NTP port
nc -u -z -w 3 192.168.100.1 123
```

## Configuration

### Device Configuration (Fallback System)

Edit the configuration section in `starlink_nmea_fallback.py`:

```python
# Configuration
STARLINK_IP = "192.168.100.1"        # Starlink router IP
STARLINK_PORT = "9200"               # Starlink API port
PRIMARY_GPS_DEVICE = "/dev/ttyACM0"  # GPS device path
PRIMARY_GPS_BAUD = 4800              # GPS baud rate
LOCK_LOSS_THRESHOLD = 120            # Seconds before fallback
UPDATE_INTERVAL = 0.2                # GPS update interval
GPS_PIPE = "/tmp/starlink_nmea_fallback"  # Named pipe for gpsd

# NTP Configuration
NTP_SERVER = "192.168.100.1"         # Starlink NTP server
NTP_TIMEOUT = 3                      # NTP query timeout
NTP_UPDATE_INTERVAL = 60             # NTP sync interval
USE_NTP = True                       # Enable NTP sync
```

### GPS Device Setup

1. **Check device path**:
   ```bash
   ls -la /dev/ttyACM*
   ```

2. **Set permissions** (if needed):
   ```bash
   sudo usermod -a -G dialout $USER
   # Log out and back in, or run:
   newgrp dialout
   ```

3. **Test GPS connection**:
   ```bash
   # Test with gpsmon
   sudo gpsd -N -n /dev/ttyACM0
   gpsmon
   ```

## Usage

### 1. Primary System: GPS/Starlink Fallback (`starlink_nmea_fallback.py`)

**Starting the System:**

1. **Start the fallback script**:
   ```bash
   python3 starlink_nmea_fallback.py
   ```

2. **Start gpsd** (in another terminal):
   ```bash
   sudo gpsd -N -n /tmp/starlink_nmea_fallback
   ```

3. **Test with a gpsd client**:
   ```bash
   # Raw NMEA output
   gpspipe -r
   
   # Real-time monitor
   gpsmon
   
   # JSON output
   gpspipe -w
   ```

### 2. Real-time Monitor (`starlinkpnt.sh`)

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

### 3. GPSD Bridge (`starlink_to_gpsd.sh`)

**Usage:**
```bash
# Terminal 1: Start the bridge
./starlink_to_gpsd.sh

# Terminal 2: Start GPSD
sudo gpsd -N -D 2 /tmp/starlink_nmea
```

**Features:**
- Connects to Starlink terminal via gRPC
- Generates NMEA sentences (GGA, RMC, GSA)
- Creates a named pipe for GPSD consumption
- High-speed updates (configurable, default 5Hz)

### 4. MAVLink Bridge (`starlink_to_mavlink.sh`)

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

### Systemd Service (Optional)

Create a systemd service for automatic startup:

```bash
sudo tee /etc/systemd/system/starlink-nmea-fallback.service << EOF
[Unit]
Description=Starlink NMEA Fallback System
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/path/to/script/directory
ExecStart=/usr/bin/python3 /path/to/script/starlink_nmea_fallback.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable starlink-nmea-fallback
sudo systemctl start starlink-nmea-fallback
```

## Operation Modes

### GPS Mode (Normal Operation)
- Reads NMEA sentences from u-blox GPS
- Passes through all GPS data to gpsd
- Monitors for GPS lock loss
- Updates every 0.2 seconds

### Fallback Mode (GPS Lost)
- Generates comprehensive NMEA sentences
- Uses Starlink positioning data
- Includes NTP-corrected timestamps
- Updates every 0.5 seconds
- Attempts GPS reconnection every 1 second

### Recovery Mode
- Automatically detects GPS reconnection
- Switches back to GPS mode
- Resumes normal operation

## Monitoring and Debugging

### Status Indicators

The script provides real-time status information:

```
✓ GPS data streaming
GPS: $GPRMC,060135.00,A,4706.59000,N,12234.13721,W,0.006,,110725,,,D*69

⚠ Switching to Starlink fallback
FALLBACK: $GPGGA,060143,4700.0000,N,12200.0000,W,1,8,1.0,10.0,M,0.0,M,,*6A

✓ GPS device reconnected, resuming normal operation
```

### Log Analysis

Monitor the script output for:
- **GPS data flow**: Continuous NMEA sentences
- **Fallback activation**: "Switching to Starlink fallback"
- **Recovery events**: "GPS device reconnected"
- **NTP sync status**: "NTP synchronized, offset: X.XXXs"

### Common Issues

#### GPS Device Not Found
```bash
# Check device permissions
ls -la /dev/ttyACM0

# Add user to dialout group
sudo usermod -a -G dialout $USER
```

#### gpsd Connection Issues
```bash
# Check if gpsd is running
ps aux | grep gpsd

# Restart gpsd
sudo pkill gpsd
sudo gpsd -N -n /tmp/starlink_nmea_fallback
```

#### NTP Sync Failures
```bash
# Test NTP server connectivity
nc -u -z -w 3 192.168.100.1 123

# Check ntpdate availability
which ntpdate
```

## Performance Characteristics

### Timing Accuracy
- **GPS Mode**: Native GPS timing accuracy
- **Fallback Mode**: NTP-corrected timing (±1-10ms typical)
- **Update Rate**: 0.2s (GPS) / 0.5s (fallback)

### Reliability
- **Automatic failover**: <1 second detection
- **Recovery time**: <2 seconds
- **Continuous operation**: 24/7 capability

### Resource Usage
- **CPU**: <5% typical
- **Memory**: <50MB
- **Network**: Minimal (NTP queries only)

## Integration Examples

### With Navigation Software
```bash
# Start the system
python3 starlink_nmea_fallback.py &
sudo gpsd -N -n /tmp/starlink_nmea_fallback

# Use with OpenCPN
opencpn --gpsd

# Use with Navit
navit --gpsd
```

### With Custom Applications
```python
import gpsd

# Connect to gpsd
gpsd.connect()

# Get current position
packet = gpsd.get_current()
print(f"Lat: {packet.lat}, Lon: {packet.lon}")
```

## Troubleshooting

### Common Issues

#### 1. Cannot connect to Starlink terminal
```bash
# Check network connectivity
ping 192.168.100.1

# Verify gRPC port is accessible
nc -zv 192.168.100.1 9200

# Check if grpcurl is installed
which grpcurl
```

#### 2. GPS Not Detected (Fallback System)
```bash
# Check device path
ls -la /dev/ttyACM*

# Verify permissions
groups $USER

# Test with gpsmon directly
sudo gpsd -N -n /dev/ttyACM0
gpsmon
```

#### 3. Fallback Not Working
```bash
# Verify Starlink connectivity
ping 192.168.100.1

# Check NTP server
nc -u -z 192.168.100.1 123

# Test ntpdate
ntpdate -q 192.168.100.1
```

#### 4. gpsd Issues
```bash
# Check pipe exists
ls -la /tmp/starlink_nmea*

# Verify gpsd process
ps aux | grep gpsd

# Check gpsd logs
journalctl -u gpsd
```

#### 5. MAVLink data not received
```bash
# Check UDP port is not blocked by firewall
sudo ufw status

# Verify ground control station is listening on the correct port
netstat -uln | grep 14550

# Use tcpdump to monitor UDP traffic
sudo tcpdump -i lo udp port 14550
```

#### 6. grpcurl not found
```bash
# Install grpcurl
sudo apt update
sudo apt install grpcurl
```

#### 7. Performance Issues
```bash
# Monitor CPU usage
top

# Check memory
free -h

# Verify disk space
df -h
```

### Testing Individual Components

#### Test GPS only (Fallback System)
```bash
python3 -c "import serial; s=serial.Serial('/dev/ttyACM0', 4800); print(s.readline())"
```

#### Test NTP sync
```bash
ntpdate -q 192.168.100.1
```

#### Test pipe communication
```bash
echo "$GPGGA,000000.00,,,,,0,0,,0.0,M,0.0,M,,*66" > /tmp/starlink_nmea_fallback
```

#### Test MAVLink output
```bash
# Listen on UDP port to see raw MAVLink data
nc -ul 14550 | hexdump -C
```

## Data Format Examples

### NMEA Output (GPSD scripts)
```
$GPGGA,123456,4807.038,N,01131.000,E,1,04,1.0,545.4,M,46.9,M,,*47
$GPRMC,123456,A,4807.038,N,01131.000,E,0.0,0.0,230394,,,*1E
$GPGSA,A,3,,,,,,,,,,,,,1.0,1.0,1.0*30
```

### MAVLink Messages (MAVLink script)
- **HEARTBEAT (ID 0)**: System status
- **GPS_RAW_INT (ID 24)**: Raw GPS data with accuracy
- **GLOBAL_POSITION_INT (ID 33)**: Position in global coordinates
- **GPS_STATUS (ID 25)**: Satellite information

### Fallback NMEA (Complete set)
```
$GPGGA,060143.50,4700.0000,N,12200.0000,W,1,8,1.0,10.0,M,0.0,M,,*6A
$GPRMC,060143.50,A,4700.0000,N,12200.0000,W,0.0,0.0,110725,,*6A
$GPVTG,0.0,T,,M,0.0,N,0.0,K,*66
$GPGLL,4700.0000,N,12200.0000,W,060143.50,A,*6A
$GPGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,1.0,1.0,1.0*30
```

## Development

### Adding New Features
- **Protocol Support**: Add new GPS protocols in the serial reading section
- **Fallback Sources**: Extend fallback data sources beyond Starlink
- **Monitoring**: Add health checks and metrics collection
- **New Output Formats**: Add support for additional navigation protocols

### Testing
```bash
# Test GPS only (Fallback System)
python3 -c "import serial; s=serial.Serial('/dev/ttyACM0', 4800); print(s.readline())"

# Test NTP sync
ntpdate -q 192.168.100.1

# Test pipe communication
echo "$GPGGA,000000.00,,,,,0,0,,0.0,M,0.0,M,,*66" > /tmp/starlink_nmea_fallback

# Test MAVLink output
nc -ul 14550 | hexdump -C
```

## Important Notes

- **NMEA Timestamps:** All NMEA timestamps are generated in UTC and, in fallback mode, are NTP-corrected using Starlink's NTP server. For best results, ensure your system clock is set to UTC.
- **Python Version:** Python 3.7+ is recommended for full compatibility with subprocess and datetime features.
- **Starlink API JSON Structure:** The fallback script expects Starlink API output as seen in grpcurl results, with location under `getLocation.lla` and GPS status under `dishGetStatus.gpsStats`.

## Known Limitations

- Fallback NMEA output does not include velocity or heading unless Starlink API provides it.
- If Starlink API is unreachable, fallback will use static placeholder values.
- NTP sync requires Starlink's NTP server to be reachable from the host.
- Only tested with u-blox 7 series GPS and Starlink Gen2/Gen3 terminals.

