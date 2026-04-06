# Shares on a Windows VM

This folder contains optional files for users who want to mount a Windows VM share on the Proxmox host and then bind it into the PiKaraoke container.

These files are **examples only**. Before using them, make sure you edit them to match your own setup.

## Files

- `mount-cifs.sh`  
  Example host-side script to mount a Windows share with CIFS/SMB

- `mount-cifs-script.service`  
  Example systemd service to run the mount script at boot

## Requirements

- A Windows VM with static IP and network shares enabled
- A shared folder with access permissions, for example:
  `\\<WinVM-IP>\<sharedpath>\<subfolder>`
  Example: `\\192.168.1.10\sharedmedia\karaoke`


## What you need to change

Before using the example files, update them for your environment:

- replace `<WinVM-IP>` with the IP address of your Windows VM
- confirm the share name is correct, for example `<sharedpath>`
- make sure your credentials file exists at `/root/.smbcredentials`
- change the PiKaraoke `<CTID>` container ID in any example bind-mount commands 

## Example credentials file

Create this file from the Proxmox host Shell:
```bash
nano /root/.smbcredentials
```
Edit the file:
```bash
nano /root/.smbcredentials
```
Add these lines:
```bash
username=YOUR_WINDOWS_USERNAME
password=YOUR_WINDOWS_PASSWORD
```

Then secure it:
```bash
chmod 600 /root/.smbcredentials
```

## Install CIFS support

```bash
apt-get update
apt-get install -y cifs-utils
```

## Create host mount point:
```bash
mkdir -p /mnt/<sharedpath>
```

## Bind the mount point into the container

Stop the container:
```bash
pct stop <CTID>
```
Bind the mount:
```bash
pct set <CTID> -mp0 /mnt/<sharedpath>/<subfolder>,mp=/mnt/pikaraoke-songs
```

## Copy the example files to Proxmox

Copy the example mount script into place:
```bash
cp extras/mount-cifs.sh /usr/local/bin/mount-cifs.sh
```
Copy the example service file into place:
```bash
cp extras/mount-cifs-script.service /etc/systemd/system/mount-cifs-script.service
```

Then run:
```bash
chmod +x /usr/local/bin/mount-cifs.sh 
systemctl daemon-reload
systemctl enable mount-cifs-script.service
systemctl start mount-cifs-script.service
```

## Finishing up

Start the container:
```bash
pct start <CTID>
```
Restart PiKaraoke if needed:
```bash
pct exec <CTID> -- systemctl restart pikaraoke
```

## Notes
- The Windows share must be mounted on the Proxmox host before the LXC starts otherwise the it may fail to start with a pre-start or mount error.
- The bind mount uses a host path, not a direct remote SMB path
- If PiKaraoke cannot see or write to the files, check host-side mount permissions and LXC permissions


