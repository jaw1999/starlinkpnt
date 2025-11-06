#!/usr/bin/env python3
"""
Starlink to UDP NMEA Bridge
Streams NMEA sentences from Starlink terminal to a UDP destination.
"""

import os
import sys
import time
import socket
import signal
import subprocess
import json
from datetime import datetime, timezone

# Configuration
STARLINK_IP = "192.168.100.1"
STARLINK_PORT = "9200"
UDP_DEST_IP = "192.68.1.100"  # Change to your destination IP
UDP_DEST_PORT = 14550          # Destination Port
UPDATE_INTERVAL = 0.2          # 5 Hz update rate
SENTENCES_PER_CYCLE = 5        # GGA, RMC, VTG, GLL, GSA

# NTP Configuration
NTP_SERVER = "192.168.100.1"
NTP_TIMEOUT = 3
NTP_UPDATE_INTERVAL = 60
USE_NTP = True

# State
ntp_offset = 0.0
ntp_last_sync = 0
ntp_available = False
udp_socket = None
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
    """Synchronize time with Starlink NTP server using sntp (cross-platform)"""
    global ntp_offset, ntp_last_sync, ntp_available

    if not USE_NTP:
        return False

    current_time = time.time()

    if current_time - ntp_last_sync < NTP_UPDATE_INTERVAL:
        return ntp_available

    if not check_ntp_server():
        ntp_available = False
        return False

    # Try sntp first (available on macOS and modern Linux)
    try:
        result = subprocess.run(
            ['sntp', '-t', str(NTP_TIMEOUT), NTP_SERVER],
            capture_output=True,
            text=True,
            timeout=NTP_TIMEOUT + 1
        )

        if result.returncode == 0 and result.stdout:
            parts = result.stdout.strip().split()
            if len(parts) > 0:
                try:
                    ntp_offset = float(parts[0])
                    ntp_last_sync = current_time
                    ntp_available = True
                    print(f"NTP sync successful, offset: {ntp_offset:.3f}s")
                    return True
                except ValueError:
                    pass

    except subprocess.TimeoutExpired:
        print("⚠ NTP sync timed out")
    except FileNotFoundError:
        # Try ntpdate as fallback (Linux only)
        try:
            result = subprocess.run(
                ['ntpdate', '-q', NTP_SERVER],
                capture_output=True,
                text=True,
                timeout=NTP_TIMEOUT
            )

            if result.returncode == 0 and result.stdout:
                for line in result.stdout.split('\n'):
                    if 'offset' in line:
                        import re
                        match = re.search(r'offset\s+([+-]?\d+\.?\d*)', line)
                        if match:
                            offset_str = match.group(1)
                            try:
                                ntp_offset = float(offset_str)
                                ntp_last_sync = current_time
                                ntp_available = True
                                print(f"NTP sync successful, offset: {ntp_offset:.3f}s")
                                return True
                            except ValueError:
                                pass
        except FileNotFoundError:
            print("Warning: Neither sntp nor ntpdate found, using system time")
            return False
        except Exception as e:
            print(f"Warning: NTP sync failed: {e}")
    except Exception as e:
        print(f"Warning: NTP sync failed: {e}")

    ntp_available = False
    return False

def get_ntp_timestamp():
    """Get NTP-corrected timestamp"""
    if ntp_available:
        return time.time() + ntp_offset
    else:
        return time.time()

def get_starlink_pnt():
    """Query Starlink API for live PNT data using grpcurl."""
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
    lat = lon = alt = accuracy = None
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
        'lat': lat, 'lon': lon, 'alt': alt, 'accuracy': accuracy,
        'gps_sats': gps_sats, 'gps_valid': gps_valid
    }

def nmea_lat(val):
    """Convert decimal latitude to NMEA format"""
    deg = int(abs(val))
    minf = (abs(val) - deg) * 60
    hemi = 'N' if val >= 0 else 'S'
    return f"{deg:02d}{minf:07.4f},{hemi}"

def nmea_lon(val):
    """Convert decimal longitude to NMEA format"""
    deg = int(abs(val))
    minf = (abs(val) - deg) * 60
    hemi = 'E' if val >= 0 else 'W'
    return f"{deg:03d}{minf:07.4f},{hemi}"

def calculate_checksum(sentence):
    """Calculate NMEA checksum"""
    checksum = 0
    for c in sentence[1:]:  # Skip the $
        checksum ^= ord(c)
    return f"{checksum:02X}"

def generate_nmea_sentences():
    """Generate NMEA sentences from Starlink PNT data"""
    pnt = get_starlink_pnt()
    lat = pnt['lat'] if pnt['lat'] is not None else 0.0
    lon = pnt['lon'] if pnt['lon'] is not None else 0.0
    alt = pnt['alt'] if pnt['alt'] is not None else 0.0
    gps_sats = pnt['gps_sats'] if pnt['gps_sats'] is not None else 0
    gps_valid = pnt['gps_valid'] if pnt['gps_valid'] is not None else False
    accuracy = 1.0

    # Skip if no valid position data
    if lat == 0.0 and lon == 0.0:
        return []

    sentences = []

    # Get NTP-corrected time
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.fromtimestamp(ntp_time, tz=timezone.utc)
    else:
        now = datetime.now(tz=timezone.utc)

    time_str = now.strftime("%H%M%S.%f")[:-4]
    date_str = now.strftime("%d%m%y")

    lat_str = nmea_lat(lat)
    lon_str = nmea_lon(lon)
    fix_quality = 1 if gps_valid else 0

    # $GPGGA - Global Positioning System Fix Data
    gga = f"$GPGGA,{time_str},{lat_str},{lon_str},{fix_quality},{gps_sats},{accuracy:.1f},{alt:.1f},M,0.0,M,,"
    sentences.append(f"{gga}*{calculate_checksum(gga)}")

    # $GPRMC - Recommended Minimum Navigation Information
    rmc = f"$GPRMC,{time_str},{'A' if gps_valid else 'V'},{lat_str},{lon_str},0.0,0.0,{date_str},,"
    sentences.append(f"{rmc}*{calculate_checksum(rmc)}")

    # $GPVTG - Track Made Good and Ground Speed
    vtg = f"$GPVTG,0.0,T,,M,0.0,N,0.0,K,"
    sentences.append(f"{vtg}*{calculate_checksum(vtg)}")

    # $GPGLL - Geographic Position - Latitude/Longitude
    gll = f"$GPGLL,{lat_str},{lon_str},{time_str},{'A' if gps_valid else 'V'},"
    sentences.append(f"{gll}*{calculate_checksum(gll)}")

    # $GPGSA - GNSS DOP and Active Satellites
    gsa = f"$GPGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,{accuracy:.1f},{accuracy:.1f},{accuracy:.1f}"
    sentences.append(f"{gsa}*{calculate_checksum(gsa)}")

    return sentences

def send_udp(message):
    """Send message via UDP"""
    global total_sent
    try:
        udp_socket.sendto(message.encode('ascii') + b'\r\n', (UDP_DEST_IP, UDP_DEST_PORT))
        total_sent += 1
        return True
    except Exception as e:
        print(f"Warning: UDP send error: {e}")
        return False

def cleanup(sig=None, frame=None):
    """Cleanup function"""
    print("\n\nCleaning up...")
    if udp_socket:
        udp_socket.close()
    print(f"Total sentences sent: {total_sent}")
    sys.exit(0)

def main():
    global udp_socket, ntp_last_sync

    print("=" * 60)
    print("Starlink to UDP NMEA Bridge")
    print("=" * 60)
    print(f"Starlink API: {STARLINK_IP}:{STARLINK_PORT}")
    print(f"UDP Destination: {UDP_DEST_IP}:{UDP_DEST_PORT}")
    print(f"Update Rate: {1/UPDATE_INTERVAL:.1f} Hz")
    print("=" * 60)
    print()

    # Setup signal handlers
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    # Create UDP socket
    try:
        udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        print(f"UDP socket created")
    except Exception as e:
        print(f"Failed to create UDP socket: {e}")
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
    print("Ready to stream NMEA data")
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

            # Generate and send NMEA sentences
            sentences = generate_nmea_sentences()

            if sentences:
                for sentence in sentences:
                    if send_udp(sentence):
                        print(f"{sentence}")
                cycle_count += 1
            else:
                print("Warning: No valid position data from Starlink")

            # Status update every 10 seconds
            if current_time - last_status_time >= 10:
                elapsed = current_time - start_time
                rate = cycle_count / (elapsed if elapsed > 0 else 1)
                print()
                print(f"Status: {cycle_count} cycles sent | {rate:.1f} cycles/s | {total_sent} sentences sent")
                print()
                last_status_time = current_time

            time.sleep(UPDATE_INTERVAL)

        except Exception as e:
            print(f"Warning: Error in main loop: {e}")
            time.sleep(1)

if __name__ == "__main__":
    main()
