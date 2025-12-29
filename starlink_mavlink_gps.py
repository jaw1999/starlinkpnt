#!/usr/bin/env python3
"""
Starlink to MAVLink GPS Injection
Injects Starlink GPS data into Cube Orange via MAVLink GPS_INPUT messages
No serial adapter needed - uses USB connection directly!
"""

import sys
import time
import signal
import subprocess
import json
from datetime import datetime, timezone
from pymavlink import mavutil

# Configuration
STARLINK_IP = "192.168.100.1"
STARLINK_PORT = "9200"
CUBE_CONNECTION = "/dev/ttyACM0"  # USB connection to Cube
CUBE_BAUD = 115200
UPDATE_INTERVAL = 0.2  # 5 Hz

# NTP Configuration
NTP_SERVER = "192.168.100.1"
NTP_TIMEOUT = 3
NTP_UPDATE_INTERVAL = 60
USE_NTP = True

# State
ntp_offset = 0.0
ntp_last_sync = 0
ntp_available = False
master = None
total_sent = 0

def check_ntp_server():
    """Check if NTP server is reachable"""
    try:
        result = subprocess.run(
            ['nc', '-u', '-z', '-w', '1', NTP_SERVER, '123'],
            capture_output=True,
            timeout=2
        )
        return result.returncode == 0
    except:
        return False

def sync_ntp_time():
    """Synchronize time with Starlink NTP server"""
    global ntp_offset, ntp_last_sync, ntp_available

    if not USE_NTP:
        return False

    current_time = time.time()
    if current_time - ntp_last_sync < NTP_UPDATE_INTERVAL:
        return ntp_available

    if not check_ntp_server():
        ntp_available = False
        return False

    # Try sntp or ntpdig (ntpdig is the replacement on Ubuntu 25.04+)
    import re
    for ntp_cmd in ['sntp', 'ntpdig']:
        try:
            result = subprocess.run(
                [ntp_cmd, '-t', str(NTP_TIMEOUT), NTP_SERVER],
                capture_output=True,
                text=True,
                timeout=NTP_TIMEOUT + 1
            )

            if result.returncode == 0 and result.stdout:
                # Parse output format:
                # "2025-12-29 09:20:42.513019 (-0500) -0.000077 +/- 0.002686 192.168.100.1 s1 no-leap"
                match = re.search(r'\)\s+([+-]?\d+\.?\d*)\s+\+/-', result.stdout)
                if match:
                    try:
                        ntp_offset = float(match.group(1))
                        ntp_last_sync = current_time
                        ntp_available = True
                        print(f"NTP sync successful, offset: {ntp_offset:.6f}s")
                        return True
                    except ValueError:
                        pass
        except FileNotFoundError:
            continue
        except:
            pass

    ntp_available = False
    return False

def get_ntp_timestamp():
    """Get NTP-corrected timestamp"""
    return time.time() + (ntp_offset if ntp_available else 0)

def get_starlink_pnt():
    """Query Starlink API for live PNT data"""
    location_cmd = [
        'grpcurl', '-plaintext', '-d', '{"get_location":{}}',
        f'{STARLINK_IP}:{STARLINK_PORT}',
        'SpaceX.API.Device.Device/Handle'
    ]
    status_cmd = [
        'grpcurl', '-plaintext', '-d', '{"get_status":{}}',
        f'{STARLINK_IP}:{STARLINK_PORT}',
        'SpaceX.API.Device.Device/Handle'
    ]

    lat = lon = alt = None
    gps_sats = gps_valid = None

    try:
        loc_out = subprocess.check_output(location_cmd, timeout=2).decode()
        loc_json = json.loads(loc_out)
        lla = loc_json.get('getLocation', {}).get('lla', {})
        lat = lla.get('lat')
        lon = lla.get('lon')
        alt = lla.get('alt')
    except Exception as e:
        print(f"Warning: Starlink get_location error: {e}")

    try:
        stat_out = subprocess.check_output(status_cmd, timeout=2).decode()
        stat_json = json.loads(stat_out)
        gps_stats = stat_json.get('dishGetStatus', {}).get('gpsStats', {})
        gps_sats = gps_stats.get('gpsSats')
        gps_valid = gps_stats.get('gpsValid')
    except Exception as e:
        print(f"Warning: Starlink get_status error: {e}")

    return {
        'lat': lat, 'lon': lon, 'alt': alt,
        'gps_sats': gps_sats, 'gps_valid': gps_valid
    }

def send_gps_input(pnt):
    """Send GPS_INPUT MAVLink message"""
    global total_sent

    if pnt['lat'] is None or pnt['lon'] is None:
        return False

    # Get NTP-synchronized time (most accurate)
    current_time = get_ntp_timestamp()
    timestamp_us = int(current_time * 1_000_000)

    # Calculate GPS time (weeks since Jan 6, 1980)
    # GPS time = UTC + leap seconds (currently 18 as of 2017)
    # GPS doesn't use leap seconds, so we need to add them back
    gps_epoch = datetime(1980, 1, 6, tzinfo=timezone.utc)
    current_dt = datetime.fromtimestamp(current_time, tz=timezone.utc)
    time_since_gps_epoch = (current_dt - gps_epoch).total_seconds()

    # Add GPS-UTC offset (leap seconds) - as of 2017, this is 18 seconds
    # This compensates for the fact that GPS time doesn't include leap seconds
    gps_utc_offset = 18  # Current leap second offset
    time_since_gps_epoch += gps_utc_offset

    # GPS week and time within week
    gps_week = int(time_since_gps_epoch / 604800)  # 604800 seconds per week
    time_week = time_since_gps_epoch % 604800
    time_week_ms = int(time_week * 1000)

    # Convert to integer format (degrees * 1e7)
    lat = int(pnt['lat'] * 1e7)
    lon = int(pnt['lon'] * 1e7)
    alt = int((pnt['alt'] if pnt['alt'] else 0) * 1000)  # meters to mm

    # Fix type: 3 = 3D fix
    fix_type = 3 if pnt.get('gps_valid') else 0
    # ArduPilot requires at least 6 satellites for a good fix
    satellites_visible = pnt.get('gps_sats') if pnt.get('gps_sats') else 10  # Default to 10 if unknown

    # Send GPS_INPUT message
    # Ignore flags: bit mask to indicate which fields should be ignored by EKF
    # Bit 0 = lat, Bit 1 = lon, Bit 2 = alt - we HAVE these, so DON'T set these bits
    # We only have: lat, lon, alt, satellites, fix_type
    # We DON'T have: hdop, vdop, velocities, accuracies
    ignore_flags = (
        8 |      # Ignore hdop (bit 3) - don't have it
        16 |     # Ignore vdop (bit 4) - don't have it
        32 |     # Ignore vel_horiz (bit 5) - don't have it
        64 |     # Ignore vel_vert (bit 6) - don't have it
        128 |    # Ignore horiz_accuracy (bit 7) - don't have it
        256 |    # Ignore vert_accuracy (bit 8) - don't have it
        512      # Ignore speed_accuracy (bit 9) - don't have it
    )
    # NOTE: Bits 0,1,2 are NOT set, so lat/lon/alt will be used

    master.mav.gps_input_send(
        timestamp_us,           # Timestamp (micros since boot or Unix epoch)
        0,                      # GPS ID (uint8)
        ignore_flags,           # Ignore flags - only use lat/lon/alt/sats
        time_week_ms,           # Time within GPS week (ms)
        gps_week,               # GPS week number
        0,                      # Time accuracy (microseconds) - don't have it
        lat,                    # Latitude (degrees * 1e7)
        lon,                    # Longitude (degrees * 1e7)
        alt,                    # Altitude (mm above MSL)
        0.0,                    # HDOP (float) - ignored
        0.0,                    # VDOP (float) - ignored
        0.0,                    # Ground speed (m/s float) - ignored
        0.0,                    # Ground track (degrees float) - ignored
        satellites_visible,     # Number of satellites (uint8)
        fix_type,               # Fix type (uint8)
        0,                      # Horizontal accuracy (uint8 cm) - ignored
        0,                      # Vertical accuracy (uint8 cm) - ignored
        0                       # Speed accuracy (uint8 cm/s) - ignored
    )

    total_sent += 1
    return True

def cleanup(sig=None, frame=None):
    """Cleanup function"""
    print("\n\nCleaning up...")
    print(f"Total GPS messages sent: {total_sent}")
    sys.exit(0)

def main():
    global master, ntp_last_sync

    print("=" * 60)
    print("Starlink to MAVLink GPS Injection")
    print("=" * 60)
    print(f"Starlink API: {STARLINK_IP}:{STARLINK_PORT}")
    print(f"Cube Connection: {CUBE_CONNECTION} @ {CUBE_BAUD} baud")
    print(f"Update Rate: {1/UPDATE_INTERVAL:.1f} Hz")
    print()
    print("IMPORTANT: Set GPS_TYPE or GPS1_TYPE = 14 (MAVLink)")
    print("=" * 60)
    print()

    # Setup signal handlers
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # Connect to Cube Orange via MAVLink
    print(f"Connecting to Cube Orange...")
    try:
        master = mavutil.mavlink_connection(CUBE_CONNECTION, baud=CUBE_BAUD)
        print("Waiting for heartbeat...")
        master.wait_heartbeat()
        print(f"✓ Connected to system {master.target_system}, component {master.target_component}")
        print()
    except Exception as e:
        print(f"Failed to connect to Cube Orange: {e}")
        sys.exit(1)

    # Initialize NTP
    if USE_NTP:
        print(f"Initializing NTP sync with {NTP_SERVER}...")
        sync_ntp_time()
        if not ntp_available:
            print("Warning: NTP not available, using system time")
    else:
        print("NTP sync disabled, using system time")

    print()
    print("Ready to inject GPS data via MAVLink")
    print("Press Ctrl+C to stop")
    print()

    ntp_last_sync = time.time()
    cycle_count = 0
    start_time = time.time()
    last_status_time = start_time

    while True:
        try:
            # Update NTP periodically
            current_time = time.time()
            if USE_NTP and current_time - ntp_last_sync >= NTP_UPDATE_INTERVAL:
                sync_ntp_time()
                ntp_last_sync = current_time

            # Get Starlink PNT data
            pnt = get_starlink_pnt()

            # Send GPS data via MAVLink
            if send_gps_input(pnt):
                cycle_count += 1
                if pnt.get('gps_valid'):
                    print(f"✓ GPS: Lat={pnt['lat']:.6f}, Lon={pnt['lon']:.6f}, Alt={pnt['alt']:.1f}m, Sats={pnt.get('gps_sats', 0)}")
                else:
                    print(f"⚠ GPS: No valid fix, Sats={pnt.get('gps_sats', 0)}")
            else:
                print("Warning: No valid position data from Starlink")

            # Status update every 10 seconds
            if current_time - last_status_time >= 10:
                elapsed = current_time - start_time
                rate = cycle_count / (elapsed if elapsed > 0 else 1)
                print()
                print(f"Status: {cycle_count} updates sent | {rate:.1f} updates/s")
                print()
                last_status_time = current_time

            time.sleep(UPDATE_INTERVAL)

        except Exception as e:
            print(f"Warning: Error in main loop: {e}")
            time.sleep(1)

if __name__ == "__main__":
    main()
