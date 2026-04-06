#!/usr/bin/env bash
# PiKaraoke-Proxmox-LXC-Installer
# Copyright (C) 2026 MarkieSpark
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

set -euo pipefail

APP_USER="pikaraoke"
APP_HOME="/var/lib/pikaraoke"
BACKUP_DIR="${APP_HOME}/.pikaraoke.bak.$(date +%Y%m%d-%H%M%S)"

echo "Backing up PiKaraoke config..."
if [[ -d "${APP_HOME}/.pikaraoke" ]]; then
  cp -a "${APP_HOME}/.pikaraoke" "${BACKUP_DIR}"
  echo "Backup created at: ${BACKUP_DIR}"
else
  echo "No existing config directory found, skipping backup."
fi

echo "Fixing ownership on PiKaraoke directories..."
chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/.local" "${APP_HOME}/.cache" "${APP_HOME}/.pikaraoke" 2>/dev/null || true

echo "Reinstalling PiKaraoke..."
su -s /bin/bash - "${APP_USER}" -c 'export PATH="$HOME/.local/bin:$PATH" && uv tool install --reinstall --force pikaraoke'

echo "Restarting service..."
systemctl restart pikaraoke

echo
echo "PiKaraoke version:"
/var/lib/pikaraoke/.local/share/uv/tools/pikaraoke/bin/python -c 'import importlib.metadata; print(importlib.metadata.version("pikaraoke"))' || true

echo
echo "YT-DLP version:"
/var/lib/pikaraoke/.local/share/uv/tools/pikaraoke/bin/yt-dlp --version || true

echo
echo "Service status:"
systemctl status pikaraoke --no-pager || true

echo
echo "Note:"
echo "- This preserves user settings in ${APP_HOME}/.pikaraoke"
echo "- It may also refresh bundled dependencies such as yt-dlp"
echo "- It is not a dedicated yt-dlp-only updater"
