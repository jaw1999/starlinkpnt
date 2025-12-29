#!/bin/bash
#
# Starlink PNT - Pi-side installation script
# This script runs on the Raspberry Pi to install dependencies
#

set -e

INSTALL_DIR="/opt/starlinkpnt"

echo "Updating package lists..."
sudo apt-get update

echo "Installing system dependencies..."
sudo apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    gpsd \
    gpsd-clients \
    sntp \
    netcat-openbsd \
    bc \
    jq \
    curl

# Install grpcurl
echo "Installing grpcurl..."
if ! command -v grpcurl &> /dev/null; then
    ARCH=$(dpkg --print-architecture)
    GRPCURL_VERSION="1.8.9"

    case $ARCH in
        armhf)
            GRPCURL_ARCH="arm"
            ;;
        arm64|aarch64)
            GRPCURL_ARCH="arm64"
            ;;
        amd64)
            GRPCURL_ARCH="x86_64"
            ;;
        *)
            echo "Warning: Unknown architecture $ARCH"
            GRPCURL_ARCH=""
            ;;
    esac

    if [ -n "$GRPCURL_ARCH" ]; then
        GRPCURL_URL="https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_${GRPCURL_ARCH}.tar.gz"
        cd /tmp
        curl -sL "$GRPCURL_URL" -o grpcurl.tar.gz
        tar -xzf grpcurl.tar.gz
        sudo mv grpcurl /usr/local/bin/
        rm -f grpcurl.tar.gz LICENSE
        echo "grpcurl installed successfully"
    fi
else
    echo "grpcurl already installed"
fi

# Create Python virtual environment
echo "Creating Python virtual environment..."
cd "$INSTALL_DIR"
python3 -m venv venv

echo "Installing Python packages..."
source venv/bin/activate
pip install --upgrade pip
pip install pyserial pymavlink
deactivate

# Set permissions
echo "Setting permissions..."
chmod +x "$INSTALL_DIR"/*.py "$INSTALL_DIR"/*.sh 2>/dev/null || true

# Add user to dialout group
if ! groups | grep -q dialout; then
    sudo usermod -a -G dialout $USER
    echo "Added $USER to dialout group"
fi

# Create udev rules
sudo tee /etc/udev/rules.d/99-gps.rules > /dev/null << 'UDEV'
# u-blox GPS devices
SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a*", SYMLINK+="gps0", MODE="0666"
# Cube Orange / Pixhawk
SUBSYSTEM=="tty", ATTRS{idVendor}=="26ac", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="2dae", MODE="0666"
UDEV
sudo udevadm control --reload-rules
sudo udevadm trigger

# Create systemd services
echo "Creating systemd services..."

sudo tee /etc/systemd/system/starlink-udp.service > /dev/null << 'EOF'
[Unit]
Description=Starlink NMEA UDP Streamer
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/opt/starlinkpnt
ExecStart=/opt/starlinkpnt/venv/bin/python3 /opt/starlinkpnt/starlink_to_udp.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/starlink-mavlink.service > /dev/null << 'EOF'
[Unit]
Description=Starlink MAVLink GPS Injector
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/opt/starlinkpnt
ExecStart=/opt/starlinkpnt/venv/bin/python3 /opt/starlinkpnt/starlink_mavlink_gps.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/starlink-fallback.service > /dev/null << 'EOF'
[Unit]
Description=Starlink NMEA Fallback System
After=network.target gpsd.service

[Service]
Type=simple
User=pi
WorkingDirectory=/opt/starlinkpnt
ExecStart=/opt/starlinkpnt/venv/bin/python3 /opt/starlinkpnt/starlink_nmea_fallback.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

# Create helper command
echo "Creating helper command..."
sudo tee /usr/local/bin/starlink-pnt > /dev/null << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/starlinkpnt"
VENV="$INSTALL_DIR/venv/bin/python3"

case "$1" in
    udp)
        exec $VENV $INSTALL_DIR/starlink_to_udp.py
        ;;
    mavlink)
        exec $VENV $INSTALL_DIR/starlink_mavlink_gps.py
        ;;
    fallback)
        exec $VENV $INSTALL_DIR/starlink_nmea_fallback.py
        ;;
    monitor)
        exec $INSTALL_DIR/starlinkpnt.sh
        ;;
    gpsd)
        exec $INSTALL_DIR/starlink_to_gpsd.sh
        ;;
    status)
        echo "Service Status:"
        echo "---------------"
        for svc in starlink-udp starlink-mavlink starlink-fallback; do
            if systemctl is-active --quiet $svc 2>/dev/null; then
                echo "$svc: RUNNING"
            else
                echo "$svc: stopped"
            fi
        done
        ;;
    test)
        echo "Testing Starlink connection..."
        if ping -c 1 -W 3 192.168.100.1 > /dev/null 2>&1; then
            echo "[OK] Starlink router reachable"
        else
            echo "[FAIL] Cannot reach Starlink router at 192.168.100.1"
            exit 1
        fi
        if nc -zv -w 3 192.168.100.1 9200 2>&1 | grep -q succeeded; then
            echo "[OK] gRPC port 9200 accessible"
        else
            echo "[FAIL] Cannot connect to gRPC port 9200"
        fi
        ;;
    *)
        echo "Starlink PNT Helper"
        echo ""
        echo "Usage: starlink-pnt <command>"
        echo ""
        echo "Run scripts:"
        echo "  udp       - Run UDP NMEA streamer"
        echo "  mavlink   - Run MAVLink GPS injector"
        echo "  fallback  - Run NMEA fallback system"
        echo "  monitor   - Run monitoring dashboard"
        echo "  gpsd      - Run GPSD bridge"
        echo ""
        echo "Utilities:"
        echo "  status    - Show service status"
        echo "  test      - Test Starlink connectivity"
        echo ""
        echo "Service management:"
        echo "  sudo systemctl start starlink-udp"
        echo "  sudo systemctl enable starlink-udp"
        echo "  journalctl -u starlink-udp -f"
        ;;
esac
EOF
sudo chmod +x /usr/local/bin/starlink-pnt

echo ""
echo "Installation complete!"
