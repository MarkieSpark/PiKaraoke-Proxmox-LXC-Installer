# PiKaraoke-Proxmox-LXC-Installer

This repository contains an unofficial Proxmox VE LXC installer for the original upstream PiKaraoke.

- It creates a Debian LXC on Proxmox VE, installs the upstream PiKaraoke application, and configures it to run as a systemd service in headless mode.
- It is intended for people who want PiKaraoke as a normal Proxmox-managed app container rather than Docker-in-LXC.
- It is maintained separately from the upstream PiKaraoke project.

## License status

PiKaraoke itself is a separate upstream project by vicwomg and is licensed under GPLv3.

This repository contains an unofficial Proxmox VE LXC installer/wrapper for the upstream project.

## About PiKaraoke

PiKaraoke is the original upstream karaoke server project by **vicwomg**. For the main project documentation, feature list, screenshots, and non-Proxmox installation methods, please see the original repository here:

[https://github.com/vicwomg/pikaraoke](https://github.com/vicwomg/pikaraoke)

## How to use

#### One-line install from Proxmox Shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MarkieSpark/PiKaraoke-Proxmox-LXC-Installer/main/create-pikaraoke-lxc.sh)"
```

#### Alternatively: Download the script to your Proxmox host shell, make it executable, and run it.

Download installer script:
```bash
curl -fsSL https://raw.githubusercontent.com/MarkieSpark/PiKaraoke-Proxmox-LXC-Installer/main/create-pikaraoke-lxc.sh -o /root/create-pikaraoke-lxc.sh
```
Make it executable and run:
```bash
chmod +x /root/create-pikaraoke-lxc.sh && /root/create-pikaraoke-lxc.sh
```

## What this installer does
- Creates a Debian LXC on Proxmox VE as an Unprivileged Container
- Installs upstream PiKaraoke natively
- Configures PiKaraoke as a systemd service
- Runs PiKaraoke in headless mode
- Exposes the web UI on port 5555
- Uses a mount-friendly songs directory at `/mnt/pikaraoke-songs`
- Optionally allows selected splash screen preferences to be preconfigured during install

## What this installer does not do
- Fork or replace the upstream PiKaraoke application
- Use Docker or Docker Compose
- Automatically configure SMB/CIFS/NFS shares
- Manage Proxmox bind mounts for you
- Replace Proxmox lifecycle controls with app UI controls

If you want songs stored outside the container, add a Proxmox bind mount to `/mnt/pikaraoke-songs` after deployment.

## Why this exists

PiKaraoke works well as a web-based karaoke server, but Proxmox users may want it to behave like a normal LXC app:

- Its own IP or DHCP lease
- Start/stop from Proxmox
- Resource limits set in Proxmox
- Optional bind mount for songs
- No Docker layer inside the container

This project focuses on that use case.

## Requirements

- A working Proxmox VE host
- Internet access from the Proxmox host and the created container
- Template storage available for Debian LXC templates
- Container storage available for the LXC root disk

## Default deployment settings

The host-side script defaults to:
- Hostname: `pikaraoke`
- CPU cores: `2`
- RAM: `2048` MB
- Root disk: `8` GB
- Bridge: `vmbr0`
- Template storage: `local`
- Container storage: `local-lvm`
- Start on boot `enabled`
- Port: `5555`

These can be adjusted at install time.

## Optional splash preference prompts

The installer can optionally pre-seed selected PiKaraoke splash preferences. If enabled, these can be adjusted at install time:

- Disable background video `Disabled`
- Disable background music `Disabled`
- Disable the score screen after each song `Disabled`
- Hide notifications `Disabled`
- Show splash clock `Disabled`
- Hide the URL and QR code `Disabled`
- Hide all overlays, including now playing, up next, and QR code `Disabled`
- Default volume of the videos (min 0, max 100) `85`
- Volume of the background music (min 0, max 100) `30`
- The amount of idle time in seconds before the screen saver activates `300`
- The delay in seconds before starting the next song `2`

## Accessing PiKaraoke

After deployment, PiKaraoke will normally be available at:

- Main UI: `http://<CT-IP>:5555`
- Splash/player UI: `http://<CT-IP>:5555/splash`

## Songs and storage

PiKaraoke is configured to use:

`/mnt/pikaraoke-songs`

as the songs/download directory inside the container.

This path can be backed by:

- Local container storage
- A Proxmox host bind mount
- Host-mounted NAS/share storage passed through into the container

## Example: use a folder on the Proxmox host

If you want to store karaoke files directly on the Proxmox host, create a folder there first:
```
mkdir -p /srv/karaoke
```
Then bind that folder into the PiKaraoke container.

Stop the container:
```
pct stop <CTID>
```
Add the bind mount:
```
pct set <CTID> -mp0 /srv/karaoke,mp=/mnt/pikaraoke-songs
```
Start the container again:
```
pct start <CTID>
```
PiKaraoke will then use `/srv/karaoke` on the Proxmox host as its songs folder.

## Example: Windows VM Share

If you want to use a Windows VM share instead, see the files in the `extras` section of this repo for a CIFS/SMB host-mount example.
Make sure the share is already running when the container starts as it may refuse to start.

## Files in this repo

- `create-pikaraoke-lxc.sh`

Host-side script that creates the LXC and installs PiKaraoke automatically

- `update-pikaraoke-lxc.sh`

Reinstalls the upstream PiKaraoke environment, restarts the service, and preserves user settings stored in `/var/lib/pikaraoke/.pikaraoke`


## Updating

This project installs upstream PiKaraoke rather than a fork.

That is intentional: it keeps the Proxmox installer focused on deployment instead of maintaining a separate application fork.

If upstream PiKaraoke changes its install behavior or internal file layout, this installer may need small adjustments.

To refresh the installed PiKaraoke environment, from the host shell run:

```bash
pct push <CTID> /root/update-pikaraoke-lxc.sh /root/update-pikaraoke-lxc.sh
pct exec <CTID> -- bash -lc "chmod +x /root/update-pikaraoke-lxc.sh && /root/update-pikaraoke-lxc.sh"
```

## Notes and limitations

- PiKaraoke is run in headless mode, which is the natural fit for Proxmox LXC deployment
- The built-in Quit/Re/Shutdown and yt-dlp update behaviour may not map cleanly to Proxmox LXC deployment and should not be treated as upstream PiKaraoke bugs unless reproduced in a standard upstream install.
- Container lifecycle should be managed from Proxmox
- Not every PiKaraoke setting is stored in `/var/lib/pikaraoke/.pikaraoke/config.ini`

## Support and scope

This repository is focused on Proxmox VE LXC deployment and packaging. 

Please do not report installer-specific, Proxmox-specific, container-specific, or wrapper-related issues to the upstream PiKaraoke project. 

This includes behaviour affected by this deployment method, such as service control, shutdown/re behaviour, updater behaviour, filesystem/mount issues, and other differences introduced by running PiKaraoke inside a Proxmox LXC. 

Only report an issue upstream if it can also be reproduced in a standard upstream PiKaraoke installation outside of this installer.

## Tested behaviour

This installer has been tested successfully with:

- Automatic LXC creation
- Native PiKaraoke installation
- Service startup
- Stop/start and re behavior
- Web UI access
- Splash page access
- YouTube download to `/mnt/pikaraoke-songs`
 
## Credits
- Upstream PiKaraoke project: [**vicwomg**](https://github.com/vicwomg)
- Proxmox VE LXC installer and packaging in this repository: [**MarkieSpark**](https://github.com/markiespark)

## Status

Working project, still being refined.
