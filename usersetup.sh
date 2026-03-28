#!/bin/bash
# tucCANeer / doolbdash user setup script
# Arch Linux ARM — Raspberry Pi 4B
# Run as your regular user after rootsetup.sh has completed
set -e

USERNAME="doolb"

echo "==> Installing yay"
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ~
rm -rf /tmp/yay

echo "==> Installing AUR packages"
yay -S --noconfirm \
    can-utils \
    pigpio \
    ttf-jetbrains-mono-nerd

echo "==> Enabling pigpiod"
sudo systemctl enable pigpiod
sudo systemctl start pigpiod

echo "==> Verifying Python dependencies"

VENV="$HOME/.venv"
PYTHON="$VENV/bin/python"

if [ ! -d "$VENV" ]; then
    echo "==> Creating virtual environment"
    python -m venv "$VENV"
fi

"$PYTHON" -m pip install --upgrade pip cantools python-can gpiozero redis

"$PYTHON" -c "import can; import cantools; import gpiozero; import redis; print('All Python imports OK')"


echo "==> Creating project directory structure"
mkdir -p ~/tuccaneer/{tuccaneer,dbc,config,systemd,docs,tests}
mkdir -p ~/doolbdash/{gpio,display/{i3,widgets,polybar},systemd,hardware}

echo "==> Writing i3 config"
mkdir -p ~/.config/i3
cat > ~/.config/i3/config << 'EOF'
# tucCANeer / doolbdash i3 config

set $mod Mod4

# Font — JetBrains Mono Nerd for full glyph support
font pango:JetBrainsMono Nerd Font 10

# Remove title bars and borders
default_border pixel 2
default_floating_border pixel 2

# Colours
set $bg       #1e1e2e
set $fg       #cdd6f4
set $accent   #89b4fa
set $urgent   #f38ba8
set $inactive #45475a

client.focused          $accent   $accent   $bg   $accent   $accent
client.unfocused        $inactive $bg       $fg   $inactive $inactive
client.focused_inactive $inactive $bg       $fg   $inactive $inactive
client.urgent           $urgent   $urgent   $bg   $urgent   $urgent

# Wallpaper / background
exec --no-startup-id xsetroot -solid "$bg"

# Key bindings
bindsym $mod+Return exec xterm
bindsym $mod+d exec rofi -show run
bindsym $mod+q kill
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exit

# Focus
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Move
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right

# Layout
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen toggle
bindsym $mod+v split v
bindsym $mod+b split h

# MFD workspaces
set $ws1 "1: 󰢚 Powertrain"
set $ws2 "2: 󰙧 Journey"
set $ws3 "3:  System"

bindsym $mod+1 workspace $ws1
bindsym $mod+2 workspace $ws2
bindsym $mod+3 workspace $ws3

bindsym $mod+Shift+1 move container to workspace $ws1
bindsym $mod+Shift+2 move container to workspace $ws2
bindsym $mod+Shift+3 move container to workspace $ws3

# Physical button workspace cycling (mapped from GPIO momentary push)
bindsym $mod+Tab workspace next
bindsym $mod+Shift+Tab workspace prev

# Polybar
exec_always --no-startup-id ~/.config/polybar/launch.sh
EOF

echo "==> Writing polybar config"
mkdir -p ~/.config/polybar
cat > ~/.config/polybar/config.ini << 'EOF'
[colors]
bg       = #1e1e2e
fg       = #cdd6f4
accent   = #89b4fa
urgent   = #f38ba8
inactive = #45475a

[bar/main]
width            = 100%
height           = 28
background       = ${colors.bg}
foreground       = ${colors.fg}
font-0           = JetBrainsMono Nerd Font:size=10;2
font-1           = JetBrainsMono Nerd Font Mono:size=14;3
border-size      = 0
padding-left     = 1
padding-right    = 1
module-margin    = 1
modules-left     = i3
modules-center   = date
modules-right    = can-status redis-status cpu memory

[module/i3]
type             = internal/i3
format           = <label-state>
label-focused    = %name%
label-focused-foreground = ${colors.accent}
label-focused-padding    = 1
label-unfocused          = %name%
label-unfocused-foreground = ${colors.inactive}
label-unfocused-padding  = 1
label-urgent             = %name%
label-urgent-foreground  = ${colors.urgent}
label-urgent-padding     = 1

[module/date]
type             = internal/date
interval         = 1
date             = %Y-%m-%d
time             = %H:%M:%S
label            =  %date%  %time%

[module/cpu]
type             = internal/cpu
interval         = 2
format           = <label>
label            = 󰻠 %percentage%%

[module/memory]
type             = internal/memory
interval         = 2
format           = <label>
label            =  %percentage_used%%

[module/can-status]
type             = custom/script
exec             = ip link show can0 2>/dev/null | grep -q "UP" && echo "󰛶 CAN UP" || echo "󰛵 CAN DOWN"
interval         = 5
label            = %output%
format-foreground = ${colors.accent}

[module/redis-status]
type             = custom/script
exec             = valkey-cli ping 2>/dev/null | grep -q "PONG" && echo " Redis OK" || echo " Redis DOWN"
interval         = 5
label            = %output%
EOF

cat > ~/.config/polybar/launch.sh << 'EOF'
#!/bin/bash
killall -q polybar
while pgrep -u $UID -x polybar > /dev/null; do sleep 0.5; done
polybar main &
EOF
chmod +x ~/.config/polybar/launch.sh

echo "==> Writing rofi config"
mkdir -p ~/.config/rofi
cat > ~/.config/rofi/config.rasi << 'EOF'
configuration {
    modi:           "run,drun";
    font:           "JetBrainsMono Nerd Font 12";
    show-icons:     false;
}

* {
    bg:      #1e1e2e;
    fg:      #cdd6f4;
    accent:  #89b4fa;
    urgent:  #f38ba8;

    background-color:   @bg;
    text-color:         @fg;
    border-color:       @accent;
}

window {
    width:      400px;
    border:     2px;
    padding:    8px;
}

element selected {
    background-color: @accent;
    text-color:       @bg;
}
EOF

echo "==> Writing xterm config"
cat > ~/.Xresources << 'EOF'
XTerm*faceName:     JetBrainsMono Nerd Font
XTerm*faceSize:     11
XTerm*background:   #1e1e2e
XTerm*foreground:   #cdd6f4
XTerm*cursorColor:  #89b4fa
XTerm*selectToClipboard: true
EOF

echo "==> Writing placeholder tucCANeer startup config"
cat > ~/tuccaneer/config/startup.toml << 'EOF'
# tucCANeer startup configuration
# Messages sent to the CAN bus on ignition-on detection

[startup]
# Regen level to set on startup (0-3)
# 0 = no regen, 3 = maximum regen
# Set to 1 to keep friction brakes exercised
regen_level = 1

# Drive mode: "eco", "normal", "sport"
drive_mode = "normal"
EOF

echo "==> Writing tucCANeer systemd service files"
cat > ~/tuccaneer/systemd/tuccaneer-reader.service << EOF
[Unit]
Description=tucCANeer CAN Reader
After=network.target can0.service
Requires=redis.service

[Service]
Type=simple
User=doolb
ExecStart=$PYTHON /home/doolb/tuccaneer/tuccaneer/can_reader.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > ~/tuccaneer/systemd/tuccaneer-writer.service << EOF
[Unit]
Description=tucCANeer CAN Writer
After=network.target can0.service
Requires=redis.service

[Service]
Type=simple
User=doolb
ExecStart=$PYTHON /home/doolb/tuccaneer/tuccaneer/can_writer.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > ~/tuccaneer/systemd/tuccaneer-startup.service << EOF
[Unit]
Description=tucCANeer Startup Sequence
After=tuccaneer-reader.service tuccaneer-writer.service
Requires=tuccaneer-reader.service tuccaneer-writer.service

[Service]
Type=oneshot
User=doolb
ExecStart=$PYTHON /home/doolb/tuccaneer/tuccaneer/startup_sequence.py
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > ~/doolbdash/systemd/doolbdash-gpio.service << EOF
[Unit]
Description=doolbdash GPIO Handler
After=tuccaneer-startup.service
Requires=tuccaneer-startup.service

[Service]
Type=simple
User=doolb
ExecStart=$PYTHON /home/doolb/doolbdash/gpio/handler.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > ~/doolbdash/systemd/doolbdash-display.service << EOF
[Unit]
Description=doolbdash Display
After=tuccaneer-startup.service
Requires=tuccaneer-startup.service

[Service]
Type=simple
User=doolb
Environment=DISPLAY=:0
ExecStart=/usr/bin/startx
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Symlinking systemd service files"
sudo ln -sf /home/$USERNAME/tuccaneer/systemd/tuccaneer-reader.service  /etc/systemd/system/
sudo ln -sf /home/$USERNAME/tuccaneer/systemd/tuccaneer-writer.service  /etc/systemd/system/
sudo ln -sf /home/$USERNAME/tuccaneer/systemd/tuccaneer-startup.service /etc/systemd/system/
sudo ln -sf /home/$USERNAME/doolbdash/systemd/doolbdash-gpio.service    /etc/systemd/system/
sudo ln -sf /home/$USERNAME/doolbdash/systemd/doolbdash-display.service /etc/systemd/system/
sudo systemctl daemon-reload

sudo systemctl enable tuccaneer-reader.service
sudo systemctl enable tuccaneer-writer.service
sudo systemctl enable tuccaneer-startup.service
sudo systemctl enable doolbdash-gpio.service
sudo systemctl enable doolbdash-display.service

echo "==> User setup complete — reboot to verify"
