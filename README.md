# RC-App-RPi-modification-script

This script is to be ran after installing RaceCapture on a RPi.

* Modify RC file to hide bootup text
* Modify RPi files to hide bootup text
* Other bootup text removal
* Splash screen setup
* Disable functions to boot faster
* Waveshare display specific modifications
* Power button LED setup

<br><br><br><br><br><br>
  
These are the steps performed.  You can also do these manually if desired.  
• Modify RC file to hide some text  
  nano ~/.bashrc  
    Comment out this line: #echo "Starting RaceCapture!"  
    Modify this line: xinit -- -nocursor -dpms -s 0 >/dev/null 2>&1  

• Replace/remove some text during bootup  
  sudo nano /boot/firmware/cmdline.txt  
    Change this tty1 to tty3: console=tty3
    Add this to the end of the line: loglevel=0 vt.global_cursor_default=0

• This gets rid of some more text  
  touch ~/.hushlogin  
  sudo mkdir -p /etc/systemd/system/getty@tty1.service.d  
  sudo nano /etc/systemd/system/getty@tty1.service.d/noclear.conf  
    *[Service]*  
    *TTYVTDisallocate=no*  
    *ExecStart=*  
    *ExecStart=-/sbin/agetty --noclear --skip-login --nonewline --noissue --autologin lbmmiata --noclear %I $TERM*  
  sudo systemctl daemon-reexec  
  sudo systemctl daemon-reload  

• Splash screen  
  sudo apt-get install feh -y  
  nano ~/.xinitrc  
    Add this before xllvnc line  
      feh --fullscreen --hide-pointer --auto-zoom /home/lbmmiata/splash.png &  

• Disable some stuff to boot faster  
  sudo systemctl disable ModemManager  
  sudo systemctl disable bluetooth  
  sudo systemctl disable triggerhappy  
  sudo systemctl disable rp1-test glamor-test  
  sudo systemctl disable alsa-restore  

• Hamburger button fix (Waveshare screen specific)  
  nano ~/.kivy/config.ini  
    Input section  
      Comment out:  
        %(name)s = probesysfs  
      Add:  
        waveshare = hidinput,/dev/input/event1  

• Ensure screen works even if RPi powers up before display  
  sudo mkdir -p /etc/X11/xorg.conf.d  
  sudo nano /etc/X11/xorg.conf.d/10-monitor.conf  
    Section "Monitor"  
      Identifier "Waveshare-9.3"  
      Modeline "1600x600_60.00" 76.50 1600 1664 1824 2048 600 603 613 624 -hsync +vsync  
      Option "PreferredMode" "1600x600_60.00"  
    EndSection  

    Section "Device"  
      Identifier "Device0"  
      Driver "modesetting"  
    EndSection  

    Section "Screen"  
      Identifier "Screen0"  
      Monitor "Waveshare-9.3"  
    EndSection  

  sudo nano /boot/firmware/config.txt  
    disable_overscan=1  
    hdmi_force_hotplug=1  
    hdmi_group=2  
    hdmi_mode=87  
    hdmi_cvt=1600 600 60 6 0 0 0  

  sudo nano /boot/firmware/cmdline.txt  
    video=HDMI-A-1:1600x600@60D  

• Power Button LED – color / fade / startup script  
  sudo apt install python3-pip -y  
  sudo pip3 install rpi-ws281x adafruit-circuitpython-neopixel --break-system-packages  

  cd /home/lbmmiata  
  mkdir scripts  
  cd scripts  
  nano chromatek_led.py  

    #!/usr/bin/env python3  

    import time  
    import signal  
    import sys  
    import board  
    import neopixel  

    PIXEL_PIN = board.D23  
    NUM_PIXELS = 1  
    BRIGHTNESS = 0.25  
    TARGET_COLOR = (0, 184, 224)  
    FADE_TIME = 1.0  
    FADE_STEPS = 50  

    pixels = neopixel.NeoPixel(  
      PIXEL_PIN,  
      NUM_PIXELS,  
      brightness=BRIGHTNESS,  
      auto_write=False  
    )  

    shutdown_requested = False  

    def fade_in(color):  
      for i in range(FADE_STEPS + 1):  
        pixels[0] = (  
          int(color[0] * i / FADE_STEPS),  
          int(color[1] * i / FADE_STEPS),  
          int(color[2] * i / FADE_STEPS),  
        )  
        pixels.show()  
        time.sleep(FADE_TIME / FADE_STEPS)  

    def fade_out(color):  
      for i in range(FADE_STEPS, -1, -1):  
        pixels[0] = (  
          int(color[0] * i / FADE_STEPS),  
          int(color[1] * i / FADE_STEPS),  
          int(color[2] * i / FADE_STEPS),  
        )  
        pixels.show()  
        time.sleep(FADE_TIME / FADE_STEPS)  

    def handle_shutdown(signum, frame):  
      global shutdown_requested  
      shutdown_requested = True  

    signal.signal(signal.SIGTERM, handle_shutdown)  
    signal.signal(signal.SIGINT, handle_shutdown)  

    fade_in(TARGET_COLOR)  

    try:  
      while not shutdown_requested:  
        time.sleep(0.2)  
    finally:  
      fade_out(TARGET_COLOR)  
      pixels.fill((0, 0, 0))  
      pixels.show()  
      sys.exit(0)  

  chmod +x /home/lbmmiata/chromatek_led.py  

  sudo nano /etc/systemd/system/chromatek_led.service  
    [Unit]  
    Description=ChromaTek Power Switch LED control  
    After=multi-user.target  

    [Service]  
    ExecStart=/usr/bin/python3 /home/lbmmiata/chromatek_led.py  
    Restart=always  
    User=root  
    Type=simple  
    KillSignal=SIGTERM  

    [Install]  
    WantedBy=multi-user.target  

  sudo systemctl daemon-reload  
  sudo systemctl enable chromatek_led.service  
  sudo systemctl start chromatek_led.service  
