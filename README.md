# proxmox-prusa-connect-vm

One-command installer for **Prusa Connect Local** on Proxmox VE.
It creates a **Debian 13 virtual machine** (cloud image + cloud-init) and runs Prusa Connect Local as a systemd service – no cloud, no Prusa Account.

## Quick start

Run on the Proxmox host as root (via SSH):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect-vm/main/prusa-connect-vm.sh)"
```

> Always review a script before running it as root.

## Requirements

- Proxmox VE 8 or 9, amd64
- A storage with the content type **snippets** (for cloud-init). If none exists, the script offers to enable it on `local` – existing content types are kept.

## What the script does

1. Checks: root, Proxmox host, amd64, internet connection
2. Asks for VM ID, name, CPU, RAM, storage, disk, bridge, DHCP/static IP and a password for the SSH user `jffk`
3. Finds the newest `prusa_connect_amd64` release from [prusa3d/prusa-connect](https://github.com/prusa3d/prusa-connect)
4. Downloads the Debian 13 cloud image and verifies its SHA512 checksum
5. Creates the VM; cloud-init installs updates, the QEMU guest agent and Prusa Connect Local (SHA256 checked) in `/opt/prusa-connect`
6. Waits for the VM IP and the web interface, then shows the address (port 8080) and the one-time setup code
7. Removes the unfinished VM automatically if anything fails before it starts

The first boot takes about 3–8 minutes.

## Default settings

| Setting   | Recommended | Minimum |
|-----------|-------------|---------|
| CPU cores | 1           | 1       |
| RAM       | 1024 MB     | 512 MB  |
| Disk      | 10 GB       | 8 GB    |

Print files are stored on the VM disk – choose more space if you keep many G-codes.

## After the installation

1. Open `http://<vm-ip>:8080` and enter the setup code
2. Create the admin account in the wizard
3. Add a printer: download the settings file, copy it to a USB drive, load it on the printer (Settings → Network → Prusa Connect). Firmware 6.4.0 or newer is required.

Log in to the VM:

```bash
ssh jffk@<vm-ip>
```

Setup code lost? Show it inside the VM with:

```bash
sudo journalctl -u prusa-connect --no-pager
```

## Updates

Prusa Connect Local is still beta (0.x) – configuration and API may change. **Take a snapshot before every update:**

```bash
qm snapshot <VMID> before-update
```

## Troubleshooting

| Message | Meaning |
|---------|---------|
| `No internet connection` | The Proxmox host cannot reach GitHub – check DNS/gateway |
| `Checksum mismatch` | The download is damaged – run the command again; nothing was installed |
| `Could not detect the VM IP yet` | cloud-init is still running – check the VM console or your router |
| `Web interface did not answer yet` | In the VM run `cloud-init status` and `journalctl -u prusa-connect` |
| `[ROLLBACK] ... removing unfinished VM` | Installation failed; the half-created VM was removed |

## Changelog

| Version | Changes |
|---------|---------|
| 1.0.1   | Own repository (proxmox-prusa-connect-vm) |
| 1.0.0   | First release |

---
from JFFK
