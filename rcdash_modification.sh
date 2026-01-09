#!/usr/bin/env bash
set -e

############################################
# Root check
############################################
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

############################################
# Detect target user
############################################
if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
else
  TARGET_USER=$(getent passwd 1000 | cut -d: -f1)
fi

TARGET_HOME=$(eval echo "~$TARGET_USER")

############################################
# Feature flags (ENABLED by default)
############################################
ENABLE_RC_HIDE=true
ENABLE_BOOT_HIDE=true
ENABLE_EXTRA_BOOT_HIDE=true
ENABLE_SPLASH=true
ENABLE_DISABLE_SERVICES=true
ENABLE_WAVESHARE=true
ENABLE_POWER_LED=true

############################################
# Menu helpers
############################################
toggle() {
  [[ "$1" == true ]] && echo false || echo true
}

bool_status() {
  [[ "$1" == true ]] && echo "ENABLED" || echo "DISABLED"
}

show_menu() {
  clear
  echo "======================================="
  echo " Raspberry Pi Setup Configuration"
  echo "======================================="
  echo
  echo "Detected user: $TARGET_USER"
  echo
  echo "1) Modify RC boot text           [$(bool_status $ENABLE_RC_HIDE)]"
  echo "2) Hide RPi boot text            [$(bool_status $ENABLE_BOOT_HIDE)]"
  echo "3) Extra boot text removal      [$(bool_status $ENABLE_EXTRA_BOOT_HIDE)]"
  echo "4) Splash screen                 [$(bool_status $ENABLE_SPLASH)]"
  echo "5) Disable services (faster boot)[$(bool_status $ENABLE_DISABLE_SERVICES)]"
  echo "6) Waveshare display tweaks      [$(bool_status $ENABLE_WAVESHARE)]"
  echo "7) Power button LED              [$(bool_status $ENABLE_POWER_LED)]"
  echo
  echo "a) Apply configuration"
  echo "q) Quit without changes"
  echo
}

############################################
# Menu loop
############################################
while true; do
  show_menu
  read -rp "Select option: " choice

  case "$choice" in
    1) ENABLE_RC_HIDE=$(toggle $ENABLE_RC_HIDE) ;;
    2) ENABLE_BOOT_HIDE=$(toggle $ENABLE_BOOT_HIDE) ;;
    3) ENABLE_EXTRA_BOOT_HIDE=$(toggle $ENABLE_EXTRA_BOOT_HIDE) ;;
    4) ENABLE_SPLASH=$(toggle $ENABLE_SPLASH) ;;
    5) ENABLE_DISABLE_SERVICES=$(toggle $ENABLE_DISABLE_SERVICES) ;;
    6) ENABLE_WAVESHARE=$(toggle $ENABLE_WAVESHARE) ;;
    7) ENABLE_POWER_LED=$(toggle $ENABLE_POWER_LED) ;;
    a) break ;;
    q) exit 0 ;;
  esac
done

############################################
# Feature implementations
############################################

configure_rc_boot_text() {
  echo "Configuring RC boot text..."
  sed -i 's/^echo "Starting RaceCapture!"/#&/' "$TARGET_HOME/.bashrc" || true
  sed -i 's|^xinit .*|xinit -- -nocursor -dpms -s 0 >/dev/null 2>&1|' "$TARGET_HOME/.bashrc" || true
}

configure_cmdline_quiet() {
  echo "Hiding Raspberry Pi boot text..."
  sed -i 's/console=tty3/console=tty1/' /boot/firmware/cmdline.txt || true
  grep -q "loglevel=0" /boot/firmware/cmdline.txt || \
    sed -i 's/$/ loglevel=0 vt.global_cursor_default=0/' /boot/firmware/cmdline.txt
}

configure_getty_quiet() {
  echo "Removing additional boot text..."
  touch "$TARGET_HOME/.hushlogin"

  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat <<EOF >/etc/systemd/system/getty@tty1.service.d/noclear.conf
[Service]
TTYVTDisallocate=no
ExecStart=
ExecStart=-/sbin/agetty --noclear --skip-login --nonewline --noissue --autologin $TARGET_USER --noclear %I \$TERM
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
}

configure_splash() {
  echo "Setting up splash screen..."
  apt update -y
  apt install -y feh

  cat <<EOF >"$TARGET_HOME/.xinitrc"
feh --fullscreen --hide-pointer --auto-zoom $TARGET_HOME/splash.png &
EOF

  chown $TARGET_USER:$TARGET_USER "$TARGET_HOME/.xinitrc"
}

disable_services() {
  echo "Disabling unneeded services..."
  systemctl disable ModemManager bluetooth triggerhappy alsa-restore rp1-test glamor-test || true
}

configure_waveshare() {
  echo "Applying Waveshare display fixes..."
  mkdir -p "$TARGET_HOME/.kivy"
  sed -i 's/%(name)s = probesysfs/#&/' "$TARGET_HOME/.kivy/config.ini" || true
  grep -q "waveshare =" "$TARGET_HOME/.kivy/config.ini" || \
    echo "waveshare = hidinput,/dev/input/event1" >> "$TARGET_HOME/.kivy/config.ini"

  chown -R $TARGET_USER:$TARGET_USER "$TARGET_HOME/.kivy"
}

install_power_led() {
  echo "Installing power button LED service..."
  apt install -y python3-pip
  pip3 install rpi-ws281x adafruit-circuitpython-neopixel --break-system-packages

  mkdir -p "$TARGET_HOME/scripts"

  cat <<'EOF' >"$TARGET_HOME/scripts/chromatek_led.py"
#!/usr/bin/env python3
import time, signal, sys, board, neopixel

PIXEL_PIN = board.D23
NUM_PIXELS = 1
BRIGHTNESS = 0.25
TARGET_COLOR = (0, 184, 224)
FADE_TIME = 1.0
FADE_STEPS = 50

pixels = neopixel.NeoPixel(
    PIXEL_PIN, NUM_PIXELS, brightness=BRIGHTNESS, auto_write=False
)

shutdown_requested = False

def fade(color, start, end):
    step = (end - start) / FADE_STEPS
    for i in range(FADE_STEPS + 1):
        scale = start + step * i
        pixels[0] = tuple(int(c * scale) for c in color)
        pixels.show()
        time.sleep(FADE_TIME / FADE_STEPS)

def handle_shutdown(signum, frame):
    global shutdown_requested
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)

fade(TARGET_COLOR, 0, 1)

try:
    while not shutdown_requested:
        time.sleep(0.2)
finally:
    fade(TARGET_COLOR, 1, 0)
    pixels.fill((0, 0, 0))
    pixels.show()
    sys.exit(0)
EOF

  chmod +x "$TARGET_HOME/scripts/chromatek_led.py"

  cat <<EOF >/etc/systemd/system/chromatek_led.service
[Unit]
Description=ChromaTek Power Switch LED control
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 $TARGET_HOME/scripts/chromatek_led.py
Restart=always
User=root
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable chromatek_led
  systemctl start chromatek_led
}

############################################
# Apply configuration
############################################
$ENABLE_RC_HIDE && configure_rc_boot_text
$ENABLE_BOOT_HIDE && configure_cmdline_quiet
$ENABLE_EXTRA_BOOT_HIDE && configure_getty_quiet
$ENABLE_SPLASH && configure_splash
$ENABLE_DISABLE_SERVICES && disable_services
$ENABLE_WAVESHARE && configure_waveshare
$ENABLE_POWER_LED && install_power_led

echo
echo "======================================="
echo " Setup complete."
echo " Reboot recommended."
echo "======================================="
