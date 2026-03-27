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
hwclock --systohc 2>/dev/null || true

echo "==> Setting locale"
sed -i "s/#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "==> Initialising pacman keyring"
pacman-key --init
pacman-key --populate archlinuxarm

echo "==> Downloading all updates"
pacman -Syw --noconfirm

echo "==> Installing updates from cache"
pacman -Su --noconfirm

echo "==> Installing base packages"
pacman -S --noconfirm --needed \
    base-devel \
    git \
    vim \
    sudo \
    python \
    python-pip \
    python-redis \
    python-gobject \
    valkey

echo "==> Installing display stack"
pacman -S --noconfirm --needed \
    xorg-server \
    xorg-xinit \
    xorg-xrandr \
    xorg-xset \
    xorg-xsetroot \
    xterm \
    i3-wm \
    i3status \
    rofi \
    polybar \
    ttf-dejavu \
    ttf-liberation

echo "==> Installing Python packages"
pip install --break-system-packages \
    python-can \
    cantools \
    gpiozero

echo "==> Creating user: $USERNAME"
if ! id "$USERNAME" &>/dev/null; then
    useradd -m -G wheel,video,audio,input -s /bin/bash "$USERNAME"
    echo "Set password for $USERNAME:"
    passwd "$USERNAME"
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

echo "==> Writing .bash_profile for $USERNAME"
cat > /home/$USERNAME/.bash_profile << 'EOF'
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -z $DISPLAY && $XDG_VTNR -eq 1 ]] && exec startx
EOF
chown $USERNAME:$USERNAME /home/$USERNAME/.bash_profile

echo "==> Writing .bashrc for $USERNAME"
cat > /home/$USERNAME/.bashrc << 'EOF'
PS1='\[\e[34m\]\u@\h\[\e[0m\]:\[\e[36m\]\w\[\e[0m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias gs='git status'
alias gd='git diff'
alias canup='sudo ip link set can0 up type can bitrate 500000'
alias candown='sudo ip link set can0 down'
alias canlisten='candump can0'
alias canlog='candump -l can0'
EOF
chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc

echo "==> Configuring systemd-networkd for can0"
cat > /etc/systemd/network/can0.network << 'EOF'
[Match]
Name=can0

[CAN]
BitRate=500000
EOF

echo "==> Enabling services"
systemctl enable valkey
systemctl enable systemd-networkd
systemctl enable pigpiod 2>/dev/null || true

echo "==> Root setup complete — log in as $USERNAME and run ~/usersetup.sh"
