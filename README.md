# Starlink PNT (Position, Navigation, Timing)

Scripts for extracting GPS/PNT data from Starlink terminals and converting it to NMEA/MAVLink formats for navigation systems and autopilots.

## Scripts

| Script | Purpose |
|--------|---------|
| `starlink_to_udp.py` | Stream NMEA via UDP to autopilots |
| `starlink_mavlink_gps.py` | MAVLink GPS injection to Cube Orange/Pixhawk |
| `starlink_nmea_fallback.py` | GPS primary with Starlink fallback |
| `starlinkpnt.sh` | Terminal monitoring dashboard |
| `starlink_to_gpsd.sh` | NMEA bridge for gpsd |
| `deploy_to_pi.sh` | Deploy to Raspberry Pi |

## Raspberry Pi Deployment

```bash
./deploy_to_pi.sh
```

Prompts for Pi IP and username, then installs everything. After deployment:

```bash
starlink-pnt test      # Test connectivity
starlink-pnt status    # Service status
starlink-pnt udp       # Run UDP streamer
starlink-pnt mavlink   # Run MAVLink GPS
starlink-pnt monitor   # Run dashboard

# Auto-start on boot
sudo systemctl enable starlink-udp
sudo systemctl start starlink-udp
```

## Usage

### UDP NMEA Streaming

Streams NMEA to a UDP destination at 5 Hz.

```bash
python3 starlink_to_udp.py
```

Configuration (edit at top of script):
```python
UDP_DEST_IP = "192.168.1.100"
UDP_DEST_PORT = 14550
```

### MAVLink GPS Injection

Sends GPS_INPUT messages to Cube Orange/Pixhawk over USB.

```bash
python3 starlink_mavlink_gps.py
```

Requires ArduPilot `GPS_TYPE = 14` (MAVLink).

### GPS/Starlink Fallback

Uses USB GPS as primary, falls back to Starlink when GPS signal is lost.

```bash
python3 starlink_nmea_fallback.py
sudo gpsd -N -n /tmp/starlink_nmea_fallback
```

### Monitor Dashboard

```bash
./starlinkpnt.sh
```

## Requirements

### Network

- Starlink terminal at 192.168.100.1
- gRPC port 9200 accessible
- NTP port 123 accessible

Test:
```bash
ping 192.168.100.1
nc -zv 192.168.100.1 9200
sntp 192.168.100.1
```

### Dependencies

Installed automatically by `deploy_to_pi.sh`, or manually:

```bash
# Debian/Ubuntu/Raspberry Pi
sudo apt-get install python3 python3-pip python3-venv gpsd gpsd-clients sntp netcat-openbsd bc jq curl

# grpcurl
curl -sL "https://github.com/fullstorydev/grpcurl/releases/download/v1.8.9/grpcurl_1.8.9_linux_$(dpkg --print-architecture).tar.gz" | tar -xz
sudo mv grpcurl /usr/local/bin/

# Python
pip3 install pyserial pymavlink
```

## Systemd Services

Created by deployment script:

| Service | Script |
|---------|--------|
| `starlink-udp` | starlink_to_udp.py |
| `starlink-mavlink` | starlink_mavlink_gps.py |
| `starlink-fallback` | starlink_nmea_fallback.py |

```bash
sudo systemctl enable starlink-udp
sudo systemctl start starlink-udp
journalctl -u starlink-udp -f
```

## NMEA Output

```
$GPGGA,141748.73,5004.2620,N,00815.8861,E,1,14,1.0,228.6,M,0.0,M,,*51
$GPRMC,141748.73,A,5004.2620,N,00815.8861,E,0.0,0.0,291225,,*3B
$GPVTG,0.0,T,,M,0.0,N,0.0,K,*4C
$GPGLL,5004.2620,N,00815.8861,E,141748.73,A,*2F
$GPGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,1.0,1.0,1.0*30
```

## Troubleshooting

```bash
# Can't reach Starlink
ping 192.168.100.1
nc -zv 192.168.100.1 9200

# NTP not working
sntp 192.168.100.1

# Serial port access
sudo usermod -a -G dialout $USER
# Then log out and back in

# MAVLink not connecting
ls -la /dev/ttyACM*
# Check GPS_TYPE = 14 in ArduPilot
```

## Compatibility

Tested on Raspberry Pi (arm64/armhf), Ubuntu 20.04+, Debian 11+, macOS.
