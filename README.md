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
Real-time monitoring script that displays Starlink PNT data in a formatted terminal interface.

**Features:**
- Live position display
- Satellite count and GPS validity status
- Distance moved calculation
- Update rate monitoring
- Clean terminal interface

**Usage:**
```bash
./starlinkpnt.sh
```

## Requirements

All scripts require:
- `grpcurl` - For communicating with Starlink terminal
- `bc` - For mathematical calculations
- `bash` - Shell environment

Additional requirements:
- **MAVLink script**: `python3`, `nc` (netcat)
- **GPSD script**: `gpsd` (for consumption)

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
   - Check that the named pipe exists: `ls -la /tmp/starlink_nmea`
   - Verify GPSD is reading from the correct device

4. **MAVLink data not received**
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

