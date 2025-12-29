#!/bin/bash
#
# Starlink PNT - Raspberry Pi Deployment Script
#
# Deploys all Starlink PNT scripts to a Raspberry Pi and installs dependencies.
# Just run: ./deploy_to_pi.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REMOTE_INSTALL_DIR="/opt/starlinkpnt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_CONTROL_PATH="/tmp/ssh-deploy-$$"

# Files to deploy
FILES_TO_COPY=(
    "starlink_nmea_fallback.py"
    "starlink_to_udp.py"
    "starlink_mavlink_gps.py"
    "starlinkpnt.sh"
    "starlink_to_gpsd.sh"
    "requirements.txt"
    "README.md"
    "pi_install.sh"
)

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

cleanup() {
    if [ -S "$SSH_CONTROL_PATH" ]; then
        ssh -O exit -o ControlPath="$SSH_CONTROL_PATH" "$PI_TARGET" 2>/dev/null || true
    fi
}
trap cleanup EXIT

print_header "Starlink PNT - Raspberry Pi Deployment"

# Ask for Pi details
echo -e "Enter Raspberry Pi details:\n"

read -p "Pi IP address (e.g., 192.168.1.50): " PI_IP
read -p "Pi username [pi]: " PI_USER
PI_USER=${PI_USER:-pi}

PI_TARGET="${PI_USER}@${PI_IP}"

echo ""
echo "Target: $PI_TARGET"
echo "Install directory: $REMOTE_INSTALL_DIR"
echo ""

# Establish persistent SSH connection (asks for password once)
print_info "Connecting to Pi (enter password once)..."
ssh -M -f -N -o ControlPath="$SSH_CONTROL_PATH" -o ControlPersist=10m "$PI_TARGET"
print_success "SSH connection established"

# Helper functions
run_ssh() {
    ssh -t -o ControlPath="$SSH_CONTROL_PATH" "$PI_TARGET" "$@"
}

run_scp() {
    scp -o ControlPath="$SSH_CONTROL_PATH" "$@"
}

# Create remote directory
print_header "Creating Remote Directory Structure"
run_ssh "sudo mkdir -p $REMOTE_INSTALL_DIR && sudo chown \$USER:\$USER $REMOTE_INSTALL_DIR"
print_success "Created $REMOTE_INSTALL_DIR"

# Copy all files
print_header "Copying Files to Raspberry Pi"

for file in "${FILES_TO_COPY[@]}"; do
    if [ -f "$SCRIPT_DIR/$file" ]; then
        run_scp "$SCRIPT_DIR/$file" "$PI_TARGET:$REMOTE_INSTALL_DIR/"
        print_success "Copied $file"
    else
        print_warning "File not found: $file"
    fi
done

# Run the install script on the Pi
print_header "Installing Dependencies on Pi"
run_ssh "chmod +x $REMOTE_INSTALL_DIR/pi_install.sh && sudo $REMOTE_INSTALL_DIR/pi_install.sh"
print_success "All dependencies installed"

# Done!
print_header "Deployment Complete!"

echo -e "Files installed to: ${GREEN}$REMOTE_INSTALL_DIR${NC}"
echo ""
echo "On the Pi, you can now run:"
echo "  starlink-pnt test      - Test Starlink connectivity"
echo "  starlink-pnt status    - Check service status"
echo "  starlink-pnt udp       - Run UDP streamer"
echo "  starlink-pnt mavlink   - Run MAVLink GPS"
echo "  starlink-pnt monitor   - Run live dashboard"
echo ""
echo "To enable a service to start on boot:"
echo "  sudo systemctl enable starlink-udp"
echo "  sudo systemctl start starlink-udp"
echo ""
print_warning "You may need to re-login to the Pi for serial port access"
