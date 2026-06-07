# Ricoh SP 111 DDST Driver for ARM64 (Raspberry Pi 4)

This repository contains a fully working CUPS driver setup for the **Ricoh SP 111 DDST** printer on **Raspberry Pi 4 / ARM64 / Debian 13 (Trixie)**, configured as a **wireless print server**.

> For x86_64 Ubuntu 24.04, use: https://github.com/jv-abhilash/ricoh-sp111-ubuntu-driver

## Architecture

```
Your Devices (Ubuntu, Windows, Android)
         │
         │ WiFi (IPP)
         ▼
   Raspberry Pi 4 (ARM64)
   ┌─────────────────────┐
   │  CUPS Print Server  │
   │  Ricoh SP111 Driver │
   └──────────┬──────────┘
              │ USB
              ▼
       Ricoh SP 111 DDST
```

## Requirements

- Raspberry Pi 4 (1GB+ RAM)
- Raspberry Pi OS Lite 64-bit / Debian 13 (Trixie) ARM64
- Ricoh SP 111 DDST connected via USB
- Internet connection for apt packages

## Installation

```bash
git clone https://github.com/jv-abhilash/ricoh-sp111-arm64-driver.git
cd ricoh-sp111-arm64-driver
sudo ./install.sh
```

## Test printing from Pi

```bash
lp -d SP-111-DDST /usr/share/cups/data/default-testpage.pdf
```

## Add printer on other devices

After installation, the installer shows your Pi's IP address. Use it to add the printer:

### Ubuntu/Linux
```
Settings → Printers → Add Printer
URI: ipp://<PI_IP>:631/printers/SP-111-DDST
```
Or via terminal:
```bash
lpadmin -p Ricoh-SP111-Network -E \
  -v ipp://<PI_IP>:631/printers/SP-111-DDST \
  -m everywhere
```

### Windows
```
Settings → Bluetooth & devices → Printers & scanners
→ Add device → The printer I want isn't listed
→ Select a shared printer by name
→ http://<PI_IP>:631/printers/SP-111-DDST
```

### Android
Install **Mopria Print Service** from Play Store.
The printer auto-discovers on the same WiFi network.

## ARM64 Specific Fixes

This repo includes fixes beyond the x86 version:

| Fix | Reason |
|-----|--------|
| `export TMPDIR=/tmp` in wrapper | CUPS sets `TMPDIR=/var/spool/cups/tmp` which blocks GS on ARM64 |
| `export HOME=/tmp` in wrapper | CUPS sets `HOME=/var/spool/cups/tmp` causing Fontconfig errors |
| Write directly to `/dev/usb/lp*` | CUPS stdout piping broken on ARM64/Debian 13 |
| `os.makedirs()` instead of `mkdir` | Ensures correct 775 permissions for `lp` user |
| GS exit code ignored | GS returns 1 on ARM64 due to Fontconfig but output is valid |
| `Sandboxing relaxed` in cups-files.conf | Debian 13 CUPS sandbox blocks filter filesystem access |
| `__temp_dir_host = "/tmp/"` | Direct `/tmp/` avoids subdir permission issues |

## File Structure

```
ricoh-sp111-arm64-driver/
  install.sh                    # One-shot installer
  ricoh-sp1xx-drv.py            # Main driver (Python 3 + ARM64 patches)
  README.md                     # This file
  .gitignore
  system-files/
    ricoh-sp1xx                 # CUPS filter entry point
    ricoh-sp1xx-wrapper         # CUPS filter wrapper (ARM64 version)
    ricoh-sp1xx.convs           # MIME conversion rules
    ricoh-sp1xx.types           # MIME type declaration
    ricoh-sp1xx.conf            # tmpfiles.d config
    SP-111-DDST.ppd             # Printer description file
    apparmor-usr.sbin.cupsd     # AppArmor rules (if needed)
```

## Troubleshooting

### Check logs
```bash
sudo cat /tmp/ricoh-wrapper.log
sudo cat /tmp/ricoh_debug.log
sudo cat /var/log/cups/error_log | tail -30
```

### Printer stopped
```bash
sudo cancel -a SP-111-DDST
sudo systemctl restart cups
cupsenable SP-111-DDST
```

### USB device not found after reconnect
```bash
sudo lpinfo -v | grep -i ricoh
# Re-add printer with new URI if needed
```

### After reboot
Everything restarts automatically. CUPS, Avahi, and tmpfiles.d are all enabled as systemd services.

## Credits

Original driver by Serge V Shistarev for Ricoh Aficio SP 1XX.
Python 3 + Ubuntu 24.04 fixes: https://github.com/jv-abhilash/ricoh-sp111-ubuntu-driver
ARM64 + Raspberry Pi wireless print server fixes by Abhilash (jv-abhilash).
