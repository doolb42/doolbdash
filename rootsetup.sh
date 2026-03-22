#!/bin/bash
# tucCANeer / doolbdash base setup script
# Arch Linux ARM — Raspberry Pi 4B
# Run as root after first boot
set -e

# ---------------------------------------------------------------
# Configuration — edit these before running
# ---------------------------------------------------------------
USERNAME="doolb"
HOSTNAME="doolbdash"
TIMEZONE="Europe/London"
LOCALE="en_GB.UTF-8"
# ---------------------------------------------------------------

echo "==> Setting hostname"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "==> Setting timezone"
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "==> Setting locale"
sed -i "s/#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "==> Updating system"
pacman -Syu --noconfirm

echo "==> Installing base packages"
pacman -S --noconfirm \
    base-devel \
    git \
    vim \
    sudo \
    python \
    python-pip \
    python-redis \
    python-gobject \
    redis \
    can-utils

echo "==> Installing display stack"
pacman -S --noconfirm \
    xorg-server \
    xorg-xinit \
    xorg-xrandr \
    xorg-xset \
    i3-wm \
    i3status \
    rofi \
    polybar \
    ttf-dejavu \
    ttf-liberation

echo "==> Installing GPIO dependencies"
pacman -S --noconfirm \
    pigpio

echo "==> Creating user: $USERNAME"
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -G wheel,video,audio,input -s /bin/bash "$USERNAME"
    echo "-------------------------------------------------------------"
    echo "  Set password for $USERNAME:"
    passwd "$USERNAME"
    echo "-------------------------------------------------------------"
else
    echo "  User $USERNAME already exists, skipping"
fi

echo "==> Configuring sudoers"
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "==> Writing .xinitrc for $USERNAME"
cat > /home/$USERNAME/.xinitrc << 'EOF'
#!/bin/sh
exec i3
EOF
chmod +x /home/$USERNAME/.xinitrc
chown $USERNAME:$USERNAME /home/$USERNAME/.xinitrc

echo "==> Enabling SPI"
if ! grep -q "dtparam=spi=on" /boot/config.txt; then
    echo "dtparam=spi=on" >> /boot/config.txt
fi

echo "==> Adding MCP2515 overlay placeholder"
if ! grep -q "mcp2515-can0" /boot/config.txt; then
    echo "" >> /boot/config.txt
    echo "# TODO: check crystal on your MCP2515 module and set oscillator to 8000000 or 16000000" >> /boot/config.txt
    echo "#dtoverlay=mcp2515-can0,oscillator=FIXME,interrupt=25" >> /boot/config.txt
fi

echo "==> Configuring systemd-networkd for can0"
cat > /etc/systemd/network/can0.network << 'EOF'
[Match]
Name=can0

[CAN]
BitRate=500000
EOF

echo "==> Enabling services"
systemctl enable redis
systemctl enable pigpiod
systemctl enable systemd-networkd

echo "==> Copying user setup script to $USERNAME home directory"
cp "$(dirname "$0")/setup-user.sh" /home/$USERNAME/setup-user.sh
chmod +x /home/$USERNAME/setup-user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/setup-user.sh

echo "==> Root setup complete — log in as $USERNAME and run ~/setup-user.sh"
