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
# Default feature flags
############################################
RC_HIDE=1
BOOT_HIDE=1
EXTRA_BOOT_HIDE=1
SPLASH=1
DISABLE_SERVICES=1
WAVESHARE=1
POWER_LED=1

eval_setting() {
  [[ "$1" -eq "$2" ]] && echo "ON" || echo "OFF"
}

############################################
# Feature selection menu
############################################
APP_SELECTIONS=$(whiptail \
  --title "RPi Setup Features" \
  --notags \
  --separate-output \
  --checklist "Choose features to enable\nDetected user: $TARGET_USER" \
  20 78 7 \
  RC_HIDE          "Modify RC boot text"              $(eval_setting $RC_HIDE 1) \
  BOOT_HIDE        "Hide Raspberry Pi boot text"      $(eval_setting $BOOT_HIDE 1) \
  EXTRA_BOOT_HIDE  "Remove additional boot text"      $(eval_setting $EXTRA_BOOT_HIDE 1) \
  SPLASH           "Splash screen setup"              $(eval_setting $SPLASH 1) \
  DISABLE_SERVICES "Disable services (faster boot)"   $(eval_setting $DISABLE_SERVICES 1) \
  WAVESHARE        "Waveshare display fixes"          $(eval_setting $WAVESHARE 1) \
  POWER_LED        "Power button LED setup"           $(eval_setting $POWER_LED 1) \
  3>&1 1>&2 2>&3
)

# Reset all to 0, enable selected
RC_HIDE=0; BOOT_HIDE=0; EXTRA_BOOT_HIDE=0; SPLASH=0; DISABLE_SERVICES=0; WAVESHARE=0; POWER_LED=0
for selection in $APP_SELECTIONS; do
  case "$selection" in
    RC_HIDE)          RC_HIDE=1 ;;
    BOOT_HIDE)        BOOT_HIDE=1 ;;
    EXTRA_BOOT_HIDE)  EXTRA_BOOT_HIDE=1 ;;
    SPLASH)           SPLASH=1 ;;
    DISABLE_SERVICES) DISABLE_SERVICES=1 ;;
    WAVESHARE)        WAVESHARE=1 ;;
    POWER_LED)        POWER_LED=1 ;;
  esac
done

############################################
# Package installation function (dynamic)
############################################
setup_packages() {
    echo "Installing packages required for selected features..."
    PACKAGES_TO_INSTALL=""

    # Splash screen requires feh
    if [[ $SPLASH -eq 1 ]]; then
        PACKAGES_TO_INSTALL+=" feh"
    fi

    # Power button LED requires python3-pip
    if [[ $POWER_LED -eq 1 ]]; then
        PACKAGES_TO_INSTALL+=" python3-pip"
    fi

    # Fix any interrupted installs first
    dpkg --configure -a || true
    apt -f install -y || true

    if [[ -n "$PACKAGES_TO_INSTALL" ]]; then
        apt update -y
        apt install -y $PACKAGES_TO_INSTALL
    else
        echo "No packages need to be installed for selected features."
    fi
}

############################################
# Feature implementations
############################################

configure_rc_boot_text() {
  echo "Configuring RC boot text..."
  sed -i '/^if shopt -q login_shell; then/,/fi/ s/^\([[:space:]]*echo[[:space:]]\+"Starting RaceCapture!"\)/# \1/' "$TARGET_HOME/.bashrc" || true
  sed -i '/^if shopt -q login_shell; then/,/fi/ s|^\([[:space:]]*\)xinit -- -nocursor -dpms -s 0[[:space:]]*$|\1xinit -- -nocursor -dpms -s 0 >/dev/null 2>\&1|' "$TARGET_HOME/.bashrc" || true
}

configure_cmdline_quiet() {
    echo "Hiding Raspberry Pi boot text..."
    sed -i 's/console=tty1/console=tty3/' /boot/firmware/cmdline.txt || true
    grep -q "loglevel=0" /boot/firmware/cmdline.txt || \
        sed -i 's/$/ loglevel=0 vt.global_cursor_default=0/' /boot/firmware/cmdline.txt
}

configure_extra_boot_text() {
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
    cat <<EOF >"$TARGET_HOME/.xinitrc"
feh --fullscreen --hide-pointer --auto-zoom $TARGET_HOME/splash.png &
EOF
    chown $TARGET_USER:$TARGET_USER "$TARGET_HOME/.xinitrc"
}

disable_services() {
    echo "Disabling services..."
    systemctl disable ModemManager bluetooth triggerhappy alsa-restore rp1-test glamor-test || true
}

configure_waveshare() {
  echo "Applying Waveshare fixes..."
  mkdir -p "$TARGET_HOME/.kivy"
  touch "$TARGET_HOME/.kivy/config.ini"
  sed -i '/^\[input\]/,/^\[/{ s/^\([[:space:]]*\)%(name)s[[:space:]]*=[[:space:]]*probesysfs[[:space:]]*$/\1#%(name)s = probesysfs/ }' "$TARGET_HOME/.kivy/config.ini"
  sed -i $'/^\[input\]/,/^\[/{ /waveshare[[:space:]]*=/b; /#%(name)s[[:space:]]*=[[:space:]]*probesysfs/a\\nwaveshare = hidinput,/dev/input/event1 }' "$TARGET_HOME/.kivy/config.ini"
  chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.kivy"
}

install_power_led() {
    echo "Installing power button LED..."
    pip3 install --no-input rpi-ws281x adafruit-circuitpython-neopixel --break-system-packages

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

pixels = neopixel.NeoPixel(PIXEL_PIN, NUM_PIXELS, brightness=BRIGHTNESS, auto_write=False)
shutdown=False

def handle(sig, frame): global shutdown; shutdown=True
signal.signal(signal.SIGTERM, handle)
signal.signal(signal.SIGINT, handle)

def fade(scale): pixels[0]=tuple(int(c*scale) for c in TARGET_COLOR); pixels.show()

for i in range(FADE_STEPS+1): fade(i/FADE_STEPS); time.sleep(FADE_TIME/FADE_STEPS)
try:
    while not shutdown: time.sleep(0.2)
finally:
    for i in range(FADE_STEPS,-1,-1): fade(i/FADE_STEPS); time.sleep(FADE_TIME/FADE_STEPS)
    pixels.fill((0,0,0)); pixels.show(); sys.exit(0)
EOF

    chmod +x "$TARGET_HOME/scripts/chromatek_led.py"

    cat <<EOF >/etc/systemd/system/chromatek_led.service
[Unit]
Description=ChromaTek Power Button LED
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
# Run everything
############################################
setup_packages

[[ $RC_HIDE -eq 1 ]]         && configure_rc_boot_text
[[ $BOOT_HIDE -eq 1 ]]       && configure_cmdline_quiet
[[ $EXTRA_BOOT_HIDE -eq 1 ]] && configure_extra_boot_text
[[ $SPLASH -eq 1 ]]          && configure_splash
[[ $DISABLE_SERVICES -eq 1 ]]&& disable_services
[[ $WAVESHARE -eq 1 ]]       && configure_waveshare
[[ $POWER_LED -eq 1 ]]       && install_power_led

whiptail --title "Setup Complete" --msgbox "Setup finished successfully.\nA reboot is recommended." 10 60
