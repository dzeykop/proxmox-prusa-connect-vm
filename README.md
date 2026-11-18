# proxmox-prusa-connect

One-command installer for **Prusa Connect Local** on Proxmox VE.
Runs Prusa Connect Local as a systemd service – no cloud, no Prusa Account.

## Quick start

Run on the Proxmox host as root (via SSH). Choose **one** of the two:

**LXC container (recommended)** – unprivileged Debian container, very light:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect/main/prusa-connect-lxc.sh)"
```

**Virtual machine** – Debian 13 cloud image with cloud-init, stronger isolation, more resources:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect/main/prusa-connect-vm.sh)"
```

> Always review a script before running it as root.

### LXC or VM?

|                  | LXC                  | VM                              |
|------------------|----------------------|---------------------------------|
| RAM (recommended)| 512 MB               | 1024 MB                         |
| Disk             | 8 GB                 | 10 GB                           |
| Install time     | ~1–2 min             | ~5–10 min (cloud-init)          |
| Isolation        | shares host kernel   | own kernel                      |
| Login            | `pct enter <CTID>`   | `ssh jffk@<vm-ip>` (password set in the installer) |

The VM installer needs a storage with the content type **snippets** for cloud-init. If none exists, it offers to enable it on `local`.

## What the script does

1. Checks: root, Proxmox host, amd64, internet connection
2. Asks for container ID, hostname, CPU, RAM, storage, disk, bridge, DHCP/static IP
3. Downloads the newest `prusa_connect_amd64` from [prusa3d/prusa-connect](https://github.com/prusa3d/prusa-connect) and verifies its SHA256 checksum
4. Downloads the newest Debian template (if needed) and creates the container
5. Installs the binary to `/opt/prusa-connect`, runs it as user `prusa-connect` via systemd
6. Shows the web address (port 8080) and the one-time setup code
7. Removes the unfinished container automatically if anything fails

## Default settings

| Setting   | LXC recommended / min | VM recommended / min |
|-----------|-----------------------|----------------------|
| CPU cores | 1 / 1                 | 1 / 1                |
| RAM       | 512 / 256 MB          | 1024 / 512 MB        |
| Disk      | 8 / 4 GB              | 10 / 8 GB            |

Print files are stored on the container disk – choose more space if you keep many G-codes.

## After the installation

1. Open `http://<container-ip>:8080` and enter the setup code
2. Create the admin account in the wizard
3. Add a printer: download the settings file, copy it to a USB drive, load it on the printer (Settings → Network → Prusa Connect). Firmware 6.4.0 or newer is required.

Setup code lost? Show it with:

```bash
# LXC (on the Proxmox host)
pct exec <CTID> -- journalctl -u prusa-connect --no-pager
# VM (inside the VM)
sudo journalctl -u prusa-connect --no-pager
```

## Updates

Prusa Connect Local is still beta (0.x) – configuration and API may change. **Take a snapshot before every update:**

```bash
pct snapshot <CTID> before-update   # LXC
qm snapshot <VMID> before-update    # VM
```

## Changelog

| Script                | Version | Changes |
|-----------------------|---------|---------|
| prusa-connect-vm.sh   | 1.0.0   | First release |
| prusa-connect-lxc.sh  | 1.0.0   | First release |

---
from JFFK
