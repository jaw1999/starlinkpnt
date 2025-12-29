#!/usr/bin/env python3
import os
import sys
import time
import signal
import subprocess
import serial
from datetime import datetime
import json

# Configuration
STARLINK_IP = "192.168.100.1"
STARLINK_PORT = "9200"
PRIMARY_GPS_DEVICE = "/dev/ttyACM0"
PRIMARY_GPS_BAUD = 4800
LOCK_LOSS_THRESHOLD = 120
UPDATE_INTERVAL = 0.2
GPS_PIPE = "/tmp/starlink_nmea_fallback"

# NTP Configuration
NTP_SERVER = "192.168.100.1"
NTP_TIMEOUT = 3
NTP_UPDATE_INTERVAL = 60
USE_NTP = True

# State
last_gps_data_time = 0
fallback_active = False

# NTP State
ntp_offset = 0.0
ntp_last_sync = 0
ntp_available = False

def setup_pipe():
    """Setup the named pipe for GPS data output"""
    print("Setting up GPS fallback pipe...")
    
    if os.path.exists(GPS_PIPE):
        if not os.path.exists(GPS_PIPE):
            os.remove(GPS_PIPE)
    if not os.path.exists(GPS_PIPE):
        os.mkfifo(GPS_PIPE)
        os.chmod(GPS_PIPE, 0o666)
    print(f"✓ GPS fallback pipe ready: {GPS_PIPE}")

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
            # Parse sntp output format:
            # "2025-12-29 09:20:42.513019 (-0500) -0.000077 +/- 0.002686 192.168.100.1 s1 no-leap"
            # The offset is after the timezone, look for the +/- pattern
            import re
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

    except subprocess.TimeoutExpired:
        print("NTP sync timed out")
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
            print("Neither sntp nor ntpdate found, NTP sync disabled")
            return False
        except Exception as e:
            print(f"NTP sync failed: {e}")
    except Exception as e:
        print(f"NTP sync failed: {e}")

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
        print(f"Starlink get_location error: {e}")
    try:
        stat_out = subprocess.check_output(status_cmd, timeout=2).decode()
        stat_json = json.loads(stat_out)
        gps_stats = stat_json.get('dishGetStatus', {}).get('gpsStats', {})
        gps_sats = gps_stats.get('gpsSats')
        gps_valid = gps_stats.get('gpsValid')
    except Exception as e:
        print(f"Starlink get_status error: {e}")
    return {
        'lat': lat, 'lon': lon, 'alt': alt, 'accuracy': accuracy,
        'gps_sats': gps_sats, 'gps_valid': gps_valid
    }

def get_starlink_sentences():
    """Generate a list of fallback NMEA sentences, each with fresh Starlink PNT and NTP-corrected time for every sentence."""
    pnt = get_starlink_pnt()
    lat = pnt['lat'] if pnt['lat'] is not None else 47.0
    lon = pnt['lon'] if pnt['lon'] is not None else -122.0
    alt = pnt['alt'] if pnt['alt'] is not None else 10.0
    gps_sats = pnt['gps_sats'] if pnt['gps_sats'] is not None else 8
    gps_valid = pnt['gps_valid'] if pnt['gps_valid'] is not None else True
    accuracy = pnt['accuracy'] if pnt['accuracy'] is not None else 1.0
    def nmea_lat(val):
        deg = int(abs(val))
        minf = (abs(val) - deg) * 60
        hemi = 'N' if val >= 0 else 'S'
        return f"{deg:02d}{minf:07.4f},{hemi}"
    def nmea_lon(val):
        deg = int(abs(val))
        minf = (abs(val) - deg) * 60
        hemi = 'E' if val >= 0 else 'W'
        return f"{deg:03d}{minf:07.4f},{hemi}"
    nmea_lat_str = nmea_lat(lat)
    nmea_lon_str = nmea_lon(lon)
    fix_quality = 1 if gps_valid else 0
    sentences = []
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.utcfromtimestamp(ntp_time)
    else:
        now = datetime.utcnow()
    time_str = now.strftime("%H%M%S.%f")[:-4]
    gga = f"$GPGGA,{time_str},{nmea_lat_str},{nmea_lon_str},{fix_quality},{gps_sats},{accuracy:.1f},{alt:.1f},M,0.0,M,,"
    checksum = 0
    for c in gga[1:]:
        checksum ^= ord(c)
    sentences.append(f"{gga}*{checksum:02X}")
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.utcfromtimestamp(ntp_time)
    else:
        now = datetime.utcnow()
    time_str = now.strftime("%H%M%S.%f")[:-4]
    date_str = now.strftime("%d%m%y")
    rmc = f"$GPRMC,{time_str},{'A' if gps_valid else 'V'},{nmea_lat_str},{nmea_lon_str},0.0,0.0,{date_str},,"
    checksum = 0
    for c in rmc[1:]:
        checksum ^= ord(c)
    sentences.append(f"{rmc}*{checksum:02X}")
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.utcfromtimestamp(ntp_time)
    else:
        now = datetime.utcnow()
    time_str = now.strftime("%H%M%S.%f")[:-4]
    vtg = f"$GPVTG,0.0,T,,M,0.0,N,0.0,K,"
    checksum = 0
    for c in vtg[1:]:
        checksum ^= ord(c)
    sentences.append(f"{vtg}*{checksum:02X}")
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.utcfromtimestamp(ntp_time)
    else:
        now = datetime.utcnow()
    time_str = now.strftime("%H%M%S.%f")[:-4]
    gll = f"$GPGLL,{nmea_lat_str},{nmea_lon_str},{time_str},{'A' if gps_valid else 'V'},"
    checksum = 0
    for c in gll[1:]:
        checksum ^= ord(c)
    sentences.append(f"{gll}*{checksum:02X}")
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.utcfromtimestamp(ntp_time)
    else:
        now = datetime.utcnow()
    time_str = now.strftime("%H%M%S.%f")[:-4]
    gsa = f"$GPGSA,A,3,01,02,03,04,05,06,07,08,09,10,11,12,{accuracy:.1f},{accuracy:.1f},{accuracy:.1f}"
    checksum = 0
    for c in gsa[1:]:
        checksum ^= ord(c)
    sentences.append(f"{gsa}*{checksum:02X}")
    if ntp_available:
        ntp_time = get_ntp_timestamp()
        now = datetime.utcfromtimestamp(ntp_time)
    else:
        now = datetime.utcnow()
    time_str = now.strftime("%H%M%S.%f")[:-4]
    zda = f"$GPZDA,{time_str},{now.day:02d},{now.month:02d},{now.year},,,"
    checksum = 0
    for c in zda[1:]:
        checksum ^= ord(c)
    sentences.append(f"{zda}*{checksum:02X}")
    return sentences

def cleanup(sig=None, frame=None):
    """Cleanup function"""
    print("Cleaning up...")
    try:
        if os.path.exists(GPS_PIPE):
            os.remove(GPS_PIPE)
    except Exception:
        pass
    sys.exit(0)

def main():
    global last_gps_data_time, fallback_active
    print("Starlink NMEA Fallback System (NMEA pass-through mode)")
    print(f"Primary GPS: {PRIMARY_GPS_DEVICE} @ {PRIMARY_GPS_BAUD} baud")
    print(f"Fallback: Starlink API ({STARLINK_IP}:{STARLINK_PORT})")
    print(f"Lock loss threshold: {LOCK_LOSS_THRESHOLD}s")
    print()
    setup_pipe()
    print(f"✓ Pipe created. Now start gpsd: sudo gpsd -N -n {GPS_PIPE}")
    print("Waiting for gpsd to connect...")
    print()

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    print("✓ Ready to stream GPS data to pipe")
    print("Start gpsd with: sudo gpsd -N -n /tmp/starlink_nmea_fallback")
    print("Then start a client like: gpspipe -r")
    print()
    
    if USE_NTP:
        print(f"Initializing NTP synchronization with {NTP_SERVER}...")
        sync_ntp_time()
        if ntp_available:
            print(f"✓ NTP synchronized, offset: {ntp_offset:.3f}s")
        else:
            print("⚠ NTP not available, using system time")
    print()

    last_ntp_sync_time = time.time()
    
    while True:
        current_time = time.time()
        if USE_NTP and current_time - last_ntp_sync_time >= NTP_UPDATE_INTERVAL:
            sync_ntp_time()
            last_ntp_sync_time = current_time
        
        try:
            with serial.Serial(PRIMARY_GPS_DEVICE, PRIMARY_GPS_BAUD, timeout=1) as ser:
                print(f"Opened {PRIMARY_GPS_DEVICE} - starting GPS data stream")
                while True:
                    line = ser.readline().decode('ascii', errors='ignore').strip()
                    now = time.time()
                    if line.startswith('$GP') or line.startswith('$GN'):
                        last_gps_data_time = now
                        if fallback_active:
                            print("GPS data resumed, switching back from fallback.")
                            fallback_active = False
                        try:
                            with open(GPS_PIPE, 'w') as pipe:
                                pipe.write(line + '\r\n')
                                pipe.flush()
                        except Exception as e:
                            print(f"Pipe write error: {e}")
                        print(f"GPS: {line}")
                    if not fallback_active and now - last_gps_data_time > LOCK_LOSS_THRESHOLD:
                        print("No GPS data, switching to Starlink fallback.")
                        fallback_active = True
                    if fallback_active:
                        sentences = get_starlink_sentences()
                        for nmea in sentences:
                            try:
                                with open(GPS_PIPE, 'w') as pipe:
                                    pipe.write(nmea + '\r\n')
                                    pipe.flush()
                            except Exception as e:
                                print(f"Pipe write error: {e}")
                            print(f"FALLBACK: {nmea}")
                            time.sleep(0.2)
                    else:
                        time.sleep(UPDATE_INTERVAL)
        except serial.SerialException as e:
            print(f"GPS device error: {e}")
            if not fallback_active:
                print("Switching to Starlink fallback due to device error.")
                fallback_active = True
            pipe_error_logged = False
            while fallback_active:
                sentences = get_starlink_sentences()
                for nmea in sentences:
                    try:
                        with open(GPS_PIPE, 'w') as pipe:
                            pipe.write(nmea + '\r\n')
                            pipe.flush()
                        pipe_error_logged = False
                    except BrokenPipeError:
                        if not pipe_error_logged:
                            print("Pipe write error: Broken pipe (no gpsd reader connected)")
                            pipe_error_logged = True
                        time.sleep(1)
                        continue
                    except Exception as e:
                        print(f"Pipe write error: {e}")
                    print(f"FALLBACK: {nmea}")
                    time.sleep(0.2)
                time.sleep(1)
                if os.path.exists(PRIMARY_GPS_DEVICE):
                    print("GPS device reconnected, resuming normal operation.")
                    fallback_active = False
                    break
        except Exception as e:
            print(f"Unexpected error: {e}")
            time.sleep(2)

if __name__ == "__main__":
    main() 