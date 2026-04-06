#!/bin/bash

SHARE="//<WinVM-IP>/<sharedpath>"
MOUNT_POINT="/mnt/<sharedpath>"
CREDENTIALS_FILE="/root/.smbcredentials"
OPTIONS="credentials=${CREDENTIALS_FILE},file_mode=0777,dir_mode=0777,iocharset=utf8,vers=3.0"

mkdir -p "$MOUNT_POINT"

while ! ping -c 1 <WinVM-IP> &> /dev/null; do
    echo "Waiting for CIFS share to become available..."
    sleep 10
done

if mountpoint -q "$MOUNT_POINT"; then
    echo "CIFS share already mounted at $MOUNT_POINT"
    exit 0
fi

mount -t cifs -o "$OPTIONS" "$SHARE" "$MOUNT_POINT"
