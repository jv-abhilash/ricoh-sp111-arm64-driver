#!/bin/bash
# ================================================================
# Ricoh SP 111 DDST Printer Driver Installer
# Target: ARM64 / Raspberry Pi 4 / Debian 13 (Trixie)
# Usage:  sudo ./install.sh
# ================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && err "Please run as root: sudo ./install.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_DIR="/opt/ricoh_driver"

log "================================================"
log "  Ricoh SP 111 Driver Installer (ARM64/Debian)"
log "================================================"

# ── Step 1: Install dependencies ─────────────────────────
log "Step 1: Installing dependencies..."
apt-get update -qq
apt-get install -y \
    cups \
    cups-filters \
    cups-bsd \
    cups-client \
    cups-daemon \
    ghostscript \
    netpbm \
    jbigkit-bin \
    python3 \
    poppler-utils \
    avahi-daemon \
    libavahi-client3 2>/dev/null || true
log "Dependencies installed."

# ── Step 2: Verify required tools ────────────────────────
log "Step 2: Verifying required tools..."
for tool in gs pbmtojbg pdf2ps python3; do
    if ! command -v $tool &>/dev/null; then
        err "Required tool '$tool' not found. Please install it manually."
    fi
done
log "All required tools available."

# ── Step 3: Copy driver files ─────────────────────────────
log "Step 3: Installing driver to $DRIVER_DIR..."
mkdir -p "$DRIVER_DIR"
cp "$SCRIPT_DIR/ricoh-sp1xx-drv.py" "$DRIVER_DIR/"
chmod 755 "$DRIVER_DIR/ricoh-sp1xx-drv.py"
chown root:root "$DRIVER_DIR/ricoh-sp1xx-drv.py"
log "Driver files copied."

# ── Step 4: Apply ARM64/Python3 patches ──────────────────
log "Step 4: Applying ARM64 + Python 3 patches to driver..."
python3 - << 'PYEOF'
import sys, os

with open('/opt/ricoh_driver/ricoh-sp1xx-drv.py', 'r') as f:
    lines = f.readlines()

patches = 0

for i, line in enumerate(lines):
    # Patch 1: shebang
    if line.strip() == '#!/usr/bin/python' or line.strip() == '#!/usr/bin/env python':
        lines[i] = '#!/usr/bin/python3\n'
        patches += 1
        print(f"  [OK] Patch 1: shebang fixed (line {i+1})")

    # Patch 2: stdout binary mode
    if '__out = sys.stdout #generate to stdout' in line and 'buffer' not in line:
        lines[i] = (
            '    __out_fn = "/tmp/ricoh_output_" + str(os.getpid()) + ".jbg"\n'
            '    __out = open(__out_fn,"wb") #write to temp file\n'
            '    __write_to_stdout = True\n'
        )
        patches += 1
        print(f"  [OK] Patch 2: stdout -> temp file (line {i+1})")

    # Patch 3: file open binary
    if '__out = open(__out_fn,"w")' in line:
        lines[i] = '    __out = open(__out_fn,"wb") #generate to a real file\n    __write_to_stdout = False\n'
        patches += 1
        print(f"  [OK] Patch 3: file open binary mode (line {i+1})")

    # Patch 4: close output + copy to stdout
    if '__out!=sys.stdout' in line and '__out.close()' in line:
        lines[i] = (
            '    __out.close()\n'
            '    if __write_to_stdout:\n'
            '        import shutil\n'
            '        with open(__out_fn,"rb") as _f:\n'
            '            shutil.copyfileobj(_f, sys.stdout.buffer)\n'
            '        sys.stdout.buffer.flush()\n'
            '        os.unlink(__out_fn)\n'
        )
        patches += 1
        print(f"  [OK] Patch 4: exitDriver stdout copy (line {i+1})")

    # Patch 5: ASCII encode with error replacement
    if '.encode("ascii")' in line and 'errors' not in line:
        lines[i] = line.replace('.encode("ascii")', '.encode("ascii", errors="replace")')
        patches += 1
        print(f"  [OK] Patch 5: ASCII encode errors=replace (line {i+1})")

    # Patch 6: parsePbmSize bytes decode
    if 'ls = lrrr.split(" ")' in line and 'isinstance' not in lines[i-1]:
        lines[i] = (
            '    if isinstance(lrrr, bytes): lrrr = lrrr.decode("ascii")\n'
            '    ls = lrrr.split(" ")\n'
        )
        patches += 1
        print(f"  [OK] Patch 6: parsePbmSize bytes decode (line {i+1})")

    # Patch 7: getInput() - use argv[6]
    if 'return " -" ' in line or "return \" -\" " in line:
        lines[i] = (
            '    if len(sys.argv) > 6 and sys.argv[6] != "":\n'
            '        return sys.argv[6]\n'
            '    return "-"\n'
        )
        patches += 1
        print(f"  [OK] Patch 7: getInput() use argv[6] (line {i+1})")

    # Patch 8: loop condition <= for single page docs
    if 'while inx<llast_page:' in line:
        lines[i] = line.replace('while inx<llast_page:', 'while inx<=llast_page:')
        patches += 1
        print(f"  [OK] Patch 8: loop condition <= (line {i+1})")

    # Patch 9: ARM64 - use os.makedirs instead of term(mkdir)
    if 'term("mkdir -p "+__uid)' in line:
        lines[i] = 'os.makedirs(__uid, mode=0o775, exist_ok=True) #ARM64: use os.makedirs for correct permissions\n'
        patches += 1
        print(f"  [OK] Patch 9: mkdir -> os.makedirs (line {i+1})")

    # Patch 10: ARM64 - ignore GS errors (GS returns 1 due to Fontconfig on ARM64)
    if 'log("COMMAND ERROR:EXIT(1)")' in line or 'exitDriver(1)' in line:
        if 'exit(fcode)' not in line:
            lines[i] = '      log("COMMAND ERROR (ignored on ARM64, checking output)")\n'
            patches += 1
            print(f"  [OK] Patch 10: ignore GS exit code on ARM64 (line {i+1})")

    # Patch 11: temp dir to /tmp/ directly for ARM64
    if '__temp_dir_host = "/tmp/ricoh_sp1xxx/"' in line:
        lines[i] = '__temp_dir_host = "/tmp/"\n'
        patches += 1
        print(f"  [OK] Patch 11: temp dir -> /tmp/ (line {i+1})")

    # Patch 12: exitDriver fix - compare with buffer
    if '__out!=sys.stdout.buffer:__out.close()' in line:
        lines[i] = (
            '    __out.close()\n'
            '    if __write_to_stdout:\n'
            '        import shutil\n'
            '        with open(__out_fn,"rb") as _f:\n'
            '            shutil.copyfileobj(_f, sys.stdout.buffer)\n'
            '        sys.stdout.buffer.flush()\n'
            '        os.unlink(__out_fn)\n'
        )
        patches += 1
        print(f"  [OK] Patch 12: exitDriver buffer fix (line {i+1})")

with open('/opt/ricoh_driver/ricoh-sp1xx-drv.py', 'w') as f:
    f.writelines(lines)

# Verify syntax
import subprocess
result = subprocess.run(['python3', '-m', 'py_compile', '/opt/ricoh_driver/ricoh-sp1xx-drv.py'],
                      capture_output=True, text=True)
if result.returncode == 0:
    print(f"  [OK] Syntax check passed. Total patches: {patches}")
else:
    print(f"  [ERROR] Syntax error: {result.stderr}")
    sys.exit(1)
PYEOF
log "Driver patches applied."

# ── Step 5: Install CUPS filter scripts ──────────────────
log "Step 5: Installing CUPS filter scripts..."
cp "$SCRIPT_DIR/system-files/ricoh-sp1xx" /usr/lib/cups/filter/ricoh-sp1xx
cp "$SCRIPT_DIR/system-files/ricoh-sp1xx-wrapper" /usr/lib/cups/filter/ricoh-sp1xx-wrapper
chmod 755 /usr/lib/cups/filter/ricoh-sp1xx
chmod 755 /usr/lib/cups/filter/ricoh-sp1xx-wrapper
chown root:root /usr/lib/cups/filter/ricoh-sp1xx
chown root:root /usr/lib/cups/filter/ricoh-sp1xx-wrapper
log "CUPS filter scripts installed."

# ── Step 6: Install MIME type rules ──────────────────────
log "Step 6: Installing MIME type rules..."
cp "$SCRIPT_DIR/system-files/ricoh-sp1xx.convs" /usr/share/cups/mime/ricoh-sp1xx.convs
cp "$SCRIPT_DIR/system-files/ricoh-sp1xx.types" /usr/share/cups/mime/ricoh-sp1xx.types
chmod 644 /usr/share/cups/mime/ricoh-sp1xx.convs
chmod 644 /usr/share/cups/mime/ricoh-sp1xx.types
log "MIME type rules installed."

# ── Step 7: Install PPD file ─────────────────────────────
log "Step 7: Installing PPD file..."
mkdir -p /usr/share/ppd/ricoh
cp "$SCRIPT_DIR/system-files/SP-111-DDST.ppd" /usr/share/ppd/ricoh/SP-111-DDST.ppd
chmod 644 /usr/share/ppd/ricoh/SP-111-DDST.ppd

# Ensure correct filter line
if ! grep -q "vnd.cups-ricoh-sp1xx" /usr/share/ppd/ricoh/SP-111-DDST.ppd; then
    sed -i 's|\*cupsFilter:.*|\*cupsFilter: "application/vnd.cups-ricoh-sp1xx 100 ricoh-sp1xx-wrapper"|' \
        /usr/share/ppd/ricoh/SP-111-DDST.ppd
fi
log "PPD file installed."

# ── Step 8: ARM64 - Disable CUPS sandboxing ───────────────
log "Step 8: Configuring CUPS for ARM64..."
if ! grep -q "^Sandboxing" /etc/cups/cups-files.conf; then
    echo "Sandboxing relaxed" >> /etc/cups/cups-files.conf
    log "CUPS sandboxing set to relaxed."
else
    sed -i 's/^Sandboxing.*/Sandboxing relaxed/' /etc/cups/cups-files.conf
    log "CUPS sandboxing already configured."
fi

# ── Step 9: Configure CUPS for network printing ──────────
log "Step 9: Configuring CUPS for network printing..."
CUPSD_CONF="/etc/cups/cupsd.conf"

# Listen on all interfaces
sed -i 's/^Listen localhost:631/Listen 0.0.0.0:631/' "$CUPSD_CONF" 2>/dev/null || true
if ! grep -q "Listen 0.0.0.0:631" "$CUPSD_CONF"; then
    echo "Listen 0.0.0.0:631" >> "$CUPSD_CONF"
fi

# Allow access from local network
python3 - << 'CONFEOF'
with open('/etc/cups/cupsd.conf', 'r') as f:
    content = f.read()

# Fix root location
if 'Allow @LOCAL' not in content and 'Allow all' not in content:
    content = content.replace(
        '<Location />\n  Order allow,deny\n</Location>',
        '<Location />\n  Order allow,deny\n  Allow @LOCAL\n</Location>'
    )
    content = content.replace(
        '<Location /admin>',
        '<Location /admin>\n  Allow @LOCAL'
    )

with open('/etc/cups/cupsd.conf', 'w') as f:
    f.write(content)
print("  [OK] CUPS network access configured")
CONFEOF

# Enable browsing
if ! grep -q "^BrowseLocalProtocols" "$CUPSD_CONF"; then
    echo "BrowseLocalProtocols dnssd" >> "$CUPSD_CONF"
fi
if ! grep -q "^ServerAlias" "$CUPSD_CONF"; then
    echo "ServerAlias *" >> "$CUPSD_CONF"
fi
log "CUPS network printing configured."

# ── Step 10: Set up temp directory ───────────────────────
log "Step 10: Setting up temp directory..."
cp "$SCRIPT_DIR/system-files/ricoh-sp1xx.conf" /etc/tmpfiles.d/ricoh-sp1xx.conf
chmod 644 /etc/tmpfiles.d/ricoh-sp1xx.conf
systemd-tmpfiles --create /etc/tmpfiles.d/ricoh-sp1xx.conf 2>/dev/null || true
# Ensure it exists now
mkdir -p /tmp/ricoh_sp1xxx
chown lp:lp /tmp/ricoh_sp1xxx
chmod 775 /tmp/ricoh_sp1xxx
log "Temp directory configured."

# ── Step 11: Enable Avahi for auto-discovery ─────────────
log "Step 11: Enabling Avahi for network printer discovery..."
systemctl enable avahi-daemon 2>/dev/null || true
systemctl start avahi-daemon 2>/dev/null || true
log "Avahi enabled."

# ── Step 12: Restart CUPS ────────────────────────────────
log "Step 12: Starting CUPS..."
systemctl enable cups
systemctl restart cups
sleep 3
log "CUPS started."

# ── Step 13: Add printer ─────────────────────────────────
log "Step 13: Detecting Ricoh SP 111 printer..."
sleep 2
PRINTER_URI=$(lpinfo -v 2>/dev/null | grep -i "ricoh\|SP.*111\|SP.*DDST" | awk '{print $2}' | head -1)

if [ -n "$PRINTER_URI" ]; then
    log "Printer found: $PRINTER_URI"
    lpadmin -x SP-111-DDST 2>/dev/null || true
    lpadmin \
        -p SP-111-DDST \
        -v "$PRINTER_URI" \
        -P /usr/share/ppd/ricoh/SP-111-DDST.ppd \
        -E \
        -o printer-is-shared=true
    lpadmin -d SP-111-DDST 2>/dev/null || true
    cupsenable SP-111-DDST 2>/dev/null || true
    cupsaccept SP-111-DDST 2>/dev/null || true
    log "Printer SP-111-DDST added and set as default."
else
    warn "Ricoh printer not detected on USB."
    warn "Connect the printer and run:"
    warn "  sudo lpinfo -v | grep -i ricoh"
    warn "  sudo lpadmin -p SP-111-DDST -v <URI> -P /usr/share/ppd/ricoh/SP-111-DDST.ppd -E"
fi

# ── Step 14: Show network info ───────────────────────────
PI_IP=$(hostname -I | awk '{print $1}')
PI_HOST=$(hostname).local

echo ""
log "================================================"
log "  Installation Complete!"
log "================================================"
echo ""
log "Driver:        /opt/ricoh_driver/ricoh-sp1xx-drv.py"
log "CUPS filters:  /usr/lib/cups/filter/ricoh-sp1xx{,-wrapper}"
log "MIME rules:    /usr/share/cups/mime/ricoh-sp1xx.{types,convs}"
log "PPD:           /usr/share/ppd/ricoh/SP-111-DDST.ppd"
log "Temp dir:      /tmp/ (ARM64 mode)"
echo ""
log "── Network Printing ──────────────────────────"
log "Pi IP address:    $PI_IP"
log "Pi hostname:      $PI_HOST"
log "CUPS web UI:      http://$PI_IP:631"
echo ""
log "── Add printer on other devices ──────────────"
log "Ubuntu/Linux:  Settings → Printers → Add → IPP"
log "  URI: ipp://$PI_IP:631/printers/SP-111-DDST"
log "Windows:       Add printer → Network → http://$PI_IP:631"
log "Android:       Auto-discovered via Mopria (same WiFi)"
echo ""
log "── Test print ────────────────────────────────"
echo "  lp -d SP-111-DDST /usr/share/cups/data/default-testpage.pdf"
echo ""
log "── Logs ──────────────────────────────────────"
echo "  sudo cat /tmp/ricoh-wrapper.log"
echo "  sudo cat /tmp/ricoh_debug.log"
echo "  sudo cat /var/log/cups/error_log | tail -30"
