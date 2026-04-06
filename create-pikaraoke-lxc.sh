#!/usr/bin/env bash
# PiKaraoke-Proxmox-LXC-Installer
# Copyright (C) 2026 MarkieSpark
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

set -euo pipefail

# Proxmox-PiKaraoke LXC Installer

# ---------------- Defaults ----------------
DEFAULT_HOSTNAME="pikaraoke"
DEFAULT_CORES="2"
DEFAULT_RAM="2048"
DEFAULT_DISK="8"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORAGE="local"
DEFAULT_ROOTFS_STORAGE="local-lvm"
DEFAULT_UNPRIVILEGED="1"
DEFAULT_ONBOOT="1"
DEFAULT_OS_PREFERRED_MAJOR="12"
DEFAULT_PORT="5555"

# Splash screen defaults (match PiKaraoke UI defaults)
DEFAULT_DISABLE_BG_VIDEO="False"
DEFAULT_DISABLE_BG_MUSIC="False"
DEFAULT_DISABLE_SCORE="False"
DEFAULT_HIDE_NOTIFICATIONS="False"
DEFAULT_SHOW_SPLASH_CLOCK="False"
DEFAULT_HIDE_URL="False"
DEFAULT_HIDE_OVERLAY="False"
DEFAULT_VOLUME="0.85"
DEFAULT_BG_MUSIC_VOLUME="0.30"
DEFAULT_SCREENSAVER_TIMEOUT="300"
DEFAULT_SPLASH_DELAY="2"

# Server settings defaults (match PiKaraoke UI defaults)
DEFAULT_NORMALIZE_AUDIO="False"
DEFAULT_HIGH_QUALITY="False"
DEFAULT_COMPLETE_TRANSCODE_BEFORE_PLAY="False"
DEFAULT_CDG_PIXEL_SCALING="False"
DEFAULT_AVSYNC="0"
DEFAULT_LIMIT_USER_SONGS_BY="0"
DEFAULT_ENABLE_FAIR_QUEUE="False"
DEFAULT_BUFFER_SIZE="150"
DEFAULT_BROWSE_RESULTS_PER_PAGE="100"

# ---------------- Helpers ----------------
msg()  { echo -e "\n[INFO] $*" >&2; }
ok()   { echo -e "[OK]   $*" >&2; }
warn() { echo -e "[WARN] $*" >&2; }
err()  { echo -e "[ERR]  $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command not found: $1"; exit 1; }
}

prompt_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  echo >&2
  echo "${value:-$default}"
}

prompt_required() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt: " value
    echo >&2
    [[ -n "$value" ]] && { echo "$value"; return; }
    warn "This value cannot be empty."
  done
}

prompt_yesno_default_n() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  echo >&2
  [[ "$answer" =~ ^[Yy]$ ]] && echo "True" || echo "False"
}

prompt_yesno_default_y() {
  local prompt="$1" answer
  read -r -p "$prompt [Y/n]: " answer
  echo >&2
  [[ "$answer" =~ ^[Nn]$ ]] && echo "False" || echo "True"
}

confirm() {
  local prompt="$1" answer
  read -r -p "$prompt [y/N]: " answer
  echo >&2
  [[ "$answer" =~ ^[Yy]$ ]]
}

find_next_ctid() {
  local id
  for id in $(seq 100 999999); do
    if ! pct status "$id" >/dev/null 2>&1; then
      echo "$id"
      return
    fi
  done
  err "Could not find a free CT ID."
  exit 1
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]
}

validate_ip() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_onboot() {
  local v="$1"
  [[ "$v" == "0" || "$v" == "1" ]]
}

validate_positive_int() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 ))
}

validate_nonneg_int() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]]
}

validate_int() {
  local v="$1"
  [[ "$v" =~ ^-?[0-9]+$ ]]
}

validate_volume_0_1() {
  local vol="$1"
  [[ "$vol" =~ ^0(\.[0-9]+)?$|^1(\.0+)?$ ]]
}

storage_exists() {
  local storage="$1"
  pvesm status | awk '{print $1}' | grep -qx "$storage"
}

bridge_exists() {
  ip link show "$1" >/dev/null 2>&1
}

find_template_name() {
  local storage="$1"
  local preferred_major="$2"
  local tpl=""

  msg "Refreshing template list on storage '$storage'..."
  pveam update >/dev/null

  tpl="$(
    pveam available -section system \
      | grep -oE "debian-${preferred_major}-standard_[^ ]+amd64\.tar\.(gz|zst)" \
      | sort -V \
      | tail -n1 || true
  )"

  if [[ -z "$tpl" ]]; then
    warn "No Debian ${preferred_major} template found. Trying Debian 12..."
    tpl="$(
      pveam available -section system \
        | grep -oE "debian-12-standard_[^ ]+amd64\.tar\.(gz|zst)" \
        | sort -V \
        | tail -n1 || true
    )"
  fi

  [[ -n "$tpl" ]] || { err "Could not find a suitable Debian template."; exit 1; }
  printf '%s\n' "$tpl"
}

ensure_template_downloaded() {
  local storage="$1" template="$2"

  if pveam list "$storage" | awk '{print $2}' | grep -qx "$template"; then
    ok "Template already present on '$storage': $template"
  else
    msg "Downloading template to '$storage': $template"
    pveam download "$storage" "$template"
    ok "Template downloaded."
  fi
}

wait_for_network() {
  local ctid="$1"
  local tries=30
  local i

  msg "Waiting for container networking..."
  for i in $(seq 1 "$tries"); do
    if pct exec "$ctid" -- bash -lc "ip route | grep -q default" >/dev/null 2>&1; then
      ok "Default route present in container."
      return 0
    fi
    sleep 2
  done

  warn "Network route did not appear within timeout. Continuing anyway."
  return 0
}

get_ct_ip() {
  local ctid="$1"
  pct exec "$ctid" -- bash -lc "hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true
}

cleanup_failed_ct() {
  local ctid="$1"
  warn "Cleaning up failed container $ctid..."
  pct stop "$ctid" >/dev/null 2>&1 || true
  pct destroy "$ctid" >/dev/null 2>&1 || true
}

bool_default_hint() {
  local value="$1"
  [[ "$value" == "True" ]] && echo "Y/n" || echo "y/N"
}

prompt_bool_with_default() {
  local prompt="$1" default_bool="$2" answer
  if [[ "$default_bool" == "True" ]]; then
    read -r -p "$prompt [Y/n]: " answer
    echo >&2
    [[ "$answer" =~ ^[Nn]$ ]] && echo "False" || echo "True"
  else
    read -r -p "$prompt [y/N]: " answer
    echo >&2
    [[ "$answer" =~ ^[Yy]$ ]] && echo "True" || echo "False"
  fi
}

# ---------------- Preflight ----------------
require_cmd pct
require_cmd pveam
require_cmd pvesm
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd ip

if [[ "${EUID}" -ne 0 ]]; then
  err "Run this script as root on the Proxmox host."
  exit 1
fi

# ---------------- Intro ----------------
echo
echo "PiKaraoke LXC Installer"
echo "Accept defaults by pressing Enter at each prompt. Please wait for the first prompt before pressing Enter."
echo

# ---------------- Core prompts ----------------
SUGGESTED_CTID="$(find_next_ctid)"
CTID="$(prompt_default "CT ID" "$SUGGESTED_CTID")"
while ! [[ "$CTID" =~ ^[0-9]+$ ]]; do
  warn "CT ID must be numeric."
  CTID="$(prompt_default "CT ID" "$SUGGESTED_CTID")"
done

HOSTNAME="$(prompt_default "Hostname" "$DEFAULT_HOSTNAME")"

CORES="$(prompt_default "CPU cores" "$DEFAULT_CORES")"
while ! validate_positive_int "$CORES"; do
  warn "CPU cores must be a positive integer."
  CORES="$(prompt_default "CPU cores" "$DEFAULT_CORES")"
done

RAM="$(prompt_default "RAM in MB" "$DEFAULT_RAM")"
while ! validate_positive_int "$RAM"; do
  warn "RAM must be a positive integer."
  RAM="$(prompt_default "RAM in MB" "$DEFAULT_RAM")"
done

DISK="$(prompt_default "Root disk in GB" "$DEFAULT_DISK")"
while ! validate_positive_int "$DISK"; do
  warn "Disk must be a positive integer."
  DISK="$(prompt_default "Root disk in GB" "$DEFAULT_DISK")"
done

BRIDGE="$(prompt_default "Bridge" "$DEFAULT_BRIDGE")"
bridge_exists "$BRIDGE" || { err "Bridge '$BRIDGE' does not exist."; exit 1; }

echo
echo "IP mode:"
echo "  1) DHCP"
echo "  2) Static"
IP_MODE_CHOICE="$(prompt_default "Choose 1 or 2" "1")"

NET_CONFIG=""
DISPLAY_IP_HINT=""

case "$IP_MODE_CHOICE" in
  1)
    NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
    DISPLAY_IP_HINT="DHCP"
    ;;
  2)
    STATIC_CIDR="$(prompt_required "Static IP/CIDR (example 10.0.0.179/24)")"
    validate_cidr "$STATIC_CIDR" || { err "Invalid IP/CIDR format."; exit 1; }
    GATEWAY="$(prompt_required "Gateway (example 10.0.0.1)")"
    validate_ip "$GATEWAY" || { err "Invalid gateway format."; exit 1; }
    NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${STATIC_CIDR},gw=${GATEWAY}"
    DISPLAY_IP_HINT="${STATIC_CIDR%/*}"
    ;;
  *)
    err "Invalid IP mode selection."
    exit 1
    ;;
esac

TEMPLATE_STORAGE="$(prompt_default "Template storage" "$DEFAULT_TEMPLATE_STORAGE")"
ROOTFS_STORAGE="$(prompt_default "Container storage" "$DEFAULT_ROOTFS_STORAGE")"

storage_exists "$TEMPLATE_STORAGE" || { err "Template storage '$TEMPLATE_STORAGE' does not exist."; exit 1; }
storage_exists "$ROOTFS_STORAGE" || { err "Container storage '$ROOTFS_STORAGE' does not exist."; exit 1; }

ONBOOT_CHOICE="$(prompt_default "Start on boot? (1=yes, 0=no)" "$DEFAULT_ONBOOT")"
while ! validate_onboot "$ONBOOT_CHOICE"; do
  warn "Enter 1 for yes or 0 for no."
  ONBOOT_CHOICE="$(prompt_default "Start on boot? (1=yes, 0=no)" "$DEFAULT_ONBOOT")"
done

PORT="$(prompt_default "PiKaraoke port" "$DEFAULT_PORT")"
while ! validate_port "$PORT"; do
  warn "Enter a valid port number from 1 to 65535."
  PORT="$(prompt_default "PiKaraoke port" "$DEFAULT_PORT")"
done

# ---------------- Splash preferences ----------------
CUSTOM_PREFS="False"
DISABLE_BG_VIDEO=""
DISABLE_BG_MUSIC=""
DISABLE_SCORE=""
HIDE_NOTIFICATIONS=""
SHOW_SPLASH_CLOCK=""
HIDE_URL=""
HIDE_OVERLAY=""
VOLUME=""
BG_MUSIC_VOLUME=""
SCREENSAVER_TIMEOUT=""
SPLASH_DELAY=""

echo
if confirm "Apply custom PiKaraoke splash preferences?"; then
  CUSTOM_PREFS="True"

  DISABLE_BG_VIDEO="$(prompt_bool_with_default "Disable background video?" "$DEFAULT_DISABLE_BG_VIDEO")"
  DISABLE_BG_MUSIC="$(prompt_bool_with_default "Disable background music?" "$DEFAULT_DISABLE_BG_MUSIC")"
  DISABLE_SCORE="$(prompt_bool_with_default "Disable score screen?" "$DEFAULT_DISABLE_SCORE")"
  HIDE_NOTIFICATIONS="$(prompt_bool_with_default "Hide notifications?" "$DEFAULT_HIDE_NOTIFICATIONS")"
  SHOW_SPLASH_CLOCK="$(prompt_bool_with_default "Show splash clock?" "$DEFAULT_SHOW_SPLASH_CLOCK")"
  HIDE_URL="$(prompt_bool_with_default "Hide URL/QR info?" "$DEFAULT_HIDE_URL")"
  HIDE_OVERLAY="$(prompt_bool_with_default "Hide all overlays?" "$DEFAULT_HIDE_OVERLAY")"

  VOLUME="$(prompt_default "Default volume (0.00 to 1.00)" "$DEFAULT_VOLUME")"
  while ! validate_volume_0_1 "$VOLUME"; do
    warn "Enter a decimal from 0.00 to 1.00."
    VOLUME="$(prompt_default "Default volume (0.00 to 1.00)" "$DEFAULT_VOLUME")"
  done

  BG_MUSIC_VOLUME="$(prompt_default "Background music volume (0.00 to 1.00)" "$DEFAULT_BG_MUSIC_VOLUME")"
  while ! validate_volume_0_1 "$BG_MUSIC_VOLUME"; do
    warn "Enter a decimal from 0.00 to 1.00."
    BG_MUSIC_VOLUME="$(prompt_default "Background music volume (0.00 to 1.00)" "$DEFAULT_BG_MUSIC_VOLUME")"
  done

  SCREENSAVER_TIMEOUT="$(prompt_default "Screensaver timeout in seconds" "$DEFAULT_SCREENSAVER_TIMEOUT")"
  while ! validate_nonneg_int "$SCREENSAVER_TIMEOUT"; do
    warn "Enter 0 or a positive integer."
    SCREENSAVER_TIMEOUT="$(prompt_default "Screensaver timeout in seconds" "$DEFAULT_SCREENSAVER_TIMEOUT")"
  done

  SPLASH_DELAY="$(prompt_default "Splash delay in seconds" "$DEFAULT_SPLASH_DELAY")"
  while ! validate_nonneg_int "$SPLASH_DELAY"; do
    warn "Enter 0 or a positive integer."
    SPLASH_DELAY="$(prompt_default "Splash delay in seconds" "$DEFAULT_SPLASH_DELAY")"
  done
fi

# ---------------- Score phrases ----------------
CUSTOM_SCORE_PHRASES="False"
LOW_SCORE_PHRASES=""
MID_SCORE_PHRASES=""
HIGH_SCORE_PHRASES=""

# Only offer score phrases if scores are enabled
# Scores are enabled when either:
# - no custom splash prefs were chosen (upstream default = enabled)
# - custom splash prefs were chosen and disable_score=False
SCORES_ENABLED="True"
if [[ "$CUSTOM_PREFS" == "True" && "$DISABLE_SCORE" == "True" ]]; then
  SCORES_ENABLED="False"
fi

if [[ "$SCORES_ENABLED" == "True" ]]; then
  echo
  if confirm "Do you want to add custom score phrases?"; then
    CUSTOM_SCORE_PHRASES="True"
    LOW_SCORE_PHRASES="$(prompt_default "Low score phrases (use | between phrases)" "")"
    MID_SCORE_PHRASES="$(prompt_default "Mid score phrases (use | between phrases)" "")"
    HIGH_SCORE_PHRASES="$(prompt_default "High score phrases (use | between phrases)" "")"
  fi
fi

# ---------------- Server settings ----------------
CUSTOM_SERVER_SETTINGS="False"
NORMALIZE_AUDIO=""
HIGH_QUALITY=""
COMPLETE_TRANSCODE_BEFORE_PLAY=""
CDG_PIXEL_SCALING=""
AVSYNC=""
LIMIT_USER_SONGS_BY=""
ENABLE_FAIR_QUEUE=""
BUFFER_SIZE=""
BROWSE_RESULTS_PER_PAGE=""
PREFERRED_LANGUAGE=""

echo
if confirm "Do you want to customise the server settings?"; then
  CUSTOM_SERVER_SETTINGS="True"

  NORMALIZE_AUDIO="$(prompt_bool_with_default "Normalize audio volume?" "$DEFAULT_NORMALIZE_AUDIO")"
  HIGH_QUALITY="$(prompt_bool_with_default "Download high quality videos?" "$DEFAULT_HIGH_QUALITY")"
  COMPLETE_TRANSCODE_BEFORE_PLAY="$(prompt_bool_with_default "Transcode video completely before playing?" "$DEFAULT_COMPLETE_TRANSCODE_BEFORE_PLAY")"
  CDG_PIXEL_SCALING="$(prompt_bool_with_default "Enable CDG pixel scaling?" "$DEFAULT_CDG_PIXEL_SCALING")"

  AVSYNC="$(prompt_default "Audio/video sync offset in seconds" "$DEFAULT_AVSYNC")"
  while ! validate_int "$AVSYNC"; do
    warn "Enter a whole number."
    AVSYNC="$(prompt_default "Audio/video sync offset in seconds" "$DEFAULT_AVSYNC")"
  done

  LIMIT_USER_SONGS_BY="$(prompt_default "Limit songs per user (0=unlimited)" "$DEFAULT_LIMIT_USER_SONGS_BY")"
  while ! validate_nonneg_int "$LIMIT_USER_SONGS_BY"; do
    warn "Enter 0 or a positive integer."
    LIMIT_USER_SONGS_BY="$(prompt_default "Limit songs per user (0=unlimited)" "$DEFAULT_LIMIT_USER_SONGS_BY")"
  done

  ENABLE_FAIR_QUEUE="$(prompt_bool_with_default "Enable fair queue?" "$DEFAULT_ENABLE_FAIR_QUEUE")"

  BUFFER_SIZE="$(prompt_default "Buffer size in KB" "$DEFAULT_BUFFER_SIZE")"
  while ! validate_positive_int "$BUFFER_SIZE"; do
    warn "Enter a positive integer."
    BUFFER_SIZE="$(prompt_default "Buffer size in KB" "$DEFAULT_BUFFER_SIZE")"
  done

  BROWSE_RESULTS_PER_PAGE="$(prompt_default "Browse results per page" "$DEFAULT_BROWSE_RESULTS_PER_PAGE")"
  while ! validate_positive_int "$BROWSE_RESULTS_PER_PAGE"; do
    warn "Enter a positive integer."
    BROWSE_RESULTS_PER_PAGE="$(prompt_default "Browse results per page" "$DEFAULT_BROWSE_RESULTS_PER_PAGE")"
  done

  if confirm "Do you want to set a preferred language?"; then
    echo
    echo "Language options:"
    echo "  1) English"
    echo "  2) German"
    echo "  3) Spanish"
    echo "  4) Finnish"
    echo "  5) French"
    echo "  6) Indonesian"
    echo "  7) Italian"
    echo "  8) Japanese"
    echo "  9) Korean"
    echo "  10) Dutch"
    echo "  11) Norwegian"
    echo "  12) Brazilian Portuguese"
    echo "  13) Russian"
    echo "  14) Thai"
    echo "  15) Chinese (Simplified)"
    echo "  16) Chinese (Traditional)"
    LANG_CHOICE="$(prompt_default "Choose language number" "1")"
    case "$LANG_CHOICE" in
      1) PREFERRED_LANGUAGE="en" ;;
      2) PREFERRED_LANGUAGE="de_DE" ;;
      3) PREFERRED_LANGUAGE="es_VE" ;;
      4) PREFERRED_LANGUAGE="fi_FI" ;;
      5) PREFERRED_LANGUAGE="fr_FR" ;;
      6) PREFERRED_LANGUAGE="id_ID" ;;
      7) PREFERRED_LANGUAGE="it_IT" ;;
      8) PREFERRED_LANGUAGE="ja_JP" ;;
      9) PREFERRED_LANGUAGE="ko_KR" ;;
      10) PREFERRED_LANGUAGE="nl_NL" ;;
      11) PREFERRED_LANGUAGE="no_NO" ;;
      12) PREFERRED_LANGUAGE="pt_BR" ;;
      13) PREFERRED_LANGUAGE="ru_RU" ;;
      14) PREFERRED_LANGUAGE="th_TH" ;;
      15) PREFERRED_LANGUAGE="zh_Hans_CN" ;;
      16) PREFERRED_LANGUAGE="zh_Hant_TW" ;;
      *) warn "Unknown language choice. Leaving language unchanged."; PREFERRED_LANGUAGE="" ;;
    esac
  fi
fi

# ---------------- Summary ----------------
echo
echo "Summary:"
echo "  CT ID:                     $CTID"
echo "  Hostname:                  $HOSTNAME"
echo "  CPU cores:                 $CORES"
echo "  RAM:                       ${RAM} MB"
echo "  Root disk:                 ${DISK} GB"
echo "  Bridge:                    $BRIDGE"
echo "  IP mode:                   $DISPLAY_IP_HINT"
echo "  Template storage:          $TEMPLATE_STORAGE"
echo "  Rootfs storage:            $ROOTFS_STORAGE"
echo "  Start on boot:             $ONBOOT_CHOICE"
echo "  Port:                      $PORT"
echo "  Custom splash prefs:       $CUSTOM_PREFS"
echo "  Custom score phrases:      $CUSTOM_SCORE_PHRASES"
echo "  Custom server settings:    $CUSTOM_SERVER_SETTINGS"

if [[ "$CUSTOM_PREFS" == "True" ]]; then
  echo "    disable_bg_video:        $DISABLE_BG_VIDEO"
  echo "    disable_bg_music:        $DISABLE_BG_MUSIC"
  echo "    disable_score:           $DISABLE_SCORE"
  echo "    hide_notifications:      $HIDE_NOTIFICATIONS"
  echo "    show_splash_clock:       $SHOW_SPLASH_CLOCK"
  echo "    hide_url:                $HIDE_URL"
  echo "    hide_overlay:            $HIDE_OVERLAY"
  echo "    volume:                  $VOLUME"
  echo "    bg_music_volume:         $BG_MUSIC_VOLUME"
  echo "    screensaver_timeout:     $SCREENSAVER_TIMEOUT"
  echo "    splash_delay:            $SPLASH_DELAY"
fi

if [[ "$CUSTOM_SCORE_PHRASES" == "True" ]]; then
  echo "    low_score_phrases:       ${LOW_SCORE_PHRASES:-<blank>}"
  echo "    mid_score_phrases:       ${MID_SCORE_PHRASES:-<blank>}"
  echo "    high_score_phrases:      ${HIGH_SCORE_PHRASES:-<blank>}"
fi

if [[ "$CUSTOM_SERVER_SETTINGS" == "True" ]]; then
  echo "    normalize_audio:         $NORMALIZE_AUDIO"
  echo "    high_quality:            $HIGH_QUALITY"
  echo "    complete_transcode...:   $COMPLETE_TRANSCODE_BEFORE_PLAY"
  echo "    cdg_pixel_scaling:       $CDG_PIXEL_SCALING"
  echo "    avsync:                  $AVSYNC"
  echo "    limit_user_songs_by:     $LIMIT_USER_SONGS_BY"
  echo "    enable_fair_queue:       $ENABLE_FAIR_QUEUE"
  echo "    buffer_size:             $BUFFER_SIZE"
  echo "    browse_results_per_page: $BROWSE_RESULTS_PER_PAGE"
  [[ -n "$PREFERRED_LANGUAGE" ]] && echo "    preferred_language:      $PREFERRED_LANGUAGE"
fi
echo

confirm "Proceed with container creation?" || { warn "Cancelled."; exit 0; }

if pct status "$CTID" >/dev/null 2>&1; then
  err "CT ID $CTID already exists."
  exit 1
fi

# ---------------- Template ----------------
TEMPLATE_NAME="$(find_template_name "$TEMPLATE_STORAGE" "$DEFAULT_OS_PREFERRED_MAJOR")"
ensure_template_downloaded "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"

# ---------------- Create CT ----------------
msg "Creating container $CTID..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap 512 \
  --rootfs "${ROOTFS_STORAGE}:${DISK}" \
  --net0 "$NET_CONFIG" \
  --unprivileged "$DEFAULT_UNPRIVILEGED" \
  --onboot "$ONBOOT_CHOICE" \
  --features nesting=1 \
  --ostype debian

ok "Container created."

msg "Starting container $CTID..."
pct start "$CTID"
ok "Container started."

wait_for_network "$CTID"

# ---------------- Embedded installer ----------------
TMP_INSTALLER="$(mktemp /tmp/pikaraoke-install.XXXXXX.sh)"

cat > "$TMP_INSTALLER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_USER="pikaraoke"
APP_HOME="/var/lib/pikaraoke"
SONGS_DIR="/mnt/pikaraoke-songs"
PORT="${PORT}"

CUSTOM_PREFS="${CUSTOM_PREFS}"
DISABLE_BG_VIDEO="${DISABLE_BG_VIDEO}"
DISABLE_BG_MUSIC="${DISABLE_BG_MUSIC}"
DISABLE_SCORE="${DISABLE_SCORE}"
HIDE_NOTIFICATIONS="${HIDE_NOTIFICATIONS}"
SHOW_SPLASH_CLOCK="${SHOW_SPLASH_CLOCK}"
HIDE_URL="${HIDE_URL}"
HIDE_OVERLAY="${HIDE_OVERLAY}"
VOLUME="${VOLUME}"
BG_MUSIC_VOLUME="${BG_MUSIC_VOLUME}"
SCREENSAVER_TIMEOUT="${SCREENSAVER_TIMEOUT}"
SPLASH_DELAY="${SPLASH_DELAY}"

CUSTOM_SCORE_PHRASES="${CUSTOM_SCORE_PHRASES}"
LOW_SCORE_PHRASES="${LOW_SCORE_PHRASES}"
MID_SCORE_PHRASES="${MID_SCORE_PHRASES}"
HIGH_SCORE_PHRASES="${HIGH_SCORE_PHRASES}"

CUSTOM_SERVER_SETTINGS="${CUSTOM_SERVER_SETTINGS}"
NORMALIZE_AUDIO="${NORMALIZE_AUDIO}"
HIGH_QUALITY="${HIGH_QUALITY}"
COMPLETE_TRANSCODE_BEFORE_PLAY="${COMPLETE_TRANSCODE_BEFORE_PLAY}"
CDG_PIXEL_SCALING="${CDG_PIXEL_SCALING}"
AVSYNC="${AVSYNC}"
LIMIT_USER_SONGS_BY="${LIMIT_USER_SONGS_BY}"
ENABLE_FAIR_QUEUE="${ENABLE_FAIR_QUEUE}"
BUFFER_SIZE="${BUFFER_SIZE}"
BROWSE_RESULTS_PER_PAGE="${BROWSE_RESULTS_PER_PAGE}"
PREFERRED_LANGUAGE="${PREFERRED_LANGUAGE}"

echo "Updating package lists..."
apt-get update

echo "Installing locale support..."
apt-get install -y locales

echo "Configuring locale..."
sed -i 's/^# *en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_GB.UTF-8

cat >/etc/default/locale <<EOL
LANG=en_GB.UTF-8
LANGUAGE=en_GB:en
EOL

export LANG=en_GB.UTF-8
export LANGUAGE=en_GB:en
unset LC_ALL

echo "Installing dependencies..."
apt-get install -y \
  ca-certificates \
  curl \
  ffmpeg \
  nodejs \
  npm \
  python3 \
  python3-venv \
  python3-pip

echo "Creating service user..."
if ! id "\${APP_USER}" >/dev/null 2>&1; then
  useradd -r -m -d "\${APP_HOME}" -s /usr/sbin/nologin "\${APP_USER}"
fi

echo "Creating directories..."
mkdir -p "\${APP_HOME}"
mkdir -p "\${SONGS_DIR}"

chown -R "\${APP_USER}:\${APP_USER}" "\${APP_HOME}"
chown -R "\${APP_USER}:\${APP_USER}" "\${SONGS_DIR}"

echo "Installing uv..."
su -s /bin/bash - "\${APP_USER}" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'

echo "Installing PiKaraoke..."
su -s /bin/bash - "\${APP_USER}" -c 'export PATH="\$HOME/.local/bin:\$PATH" && uv tool install pikaraoke'

if [[ "\${CUSTOM_PREFS}" == "True" || "\${CUSTOM_SCORE_PHRASES}" == "True" || "\${CUSTOM_SERVER_SETTINGS}" == "True" ]]; then
  echo "Writing PiKaraoke preferences..."
  CONFIG_DIR="\${APP_HOME}/.pikaraoke"
  CONFIG_FILE="\${CONFIG_DIR}/config.ini"
  mkdir -p "\${CONFIG_DIR}"

  {
    echo "[USERPREFERENCES]"

    if [[ "\${CUSTOM_PREFS}" == "True" ]]; then
      echo "disable_bg_video = \${DISABLE_BG_VIDEO}"
      echo "disable_bg_music = \${DISABLE_BG_MUSIC}"
      echo "disable_score = \${DISABLE_SCORE}"
      echo "hide_notifications = \${HIDE_NOTIFICATIONS}"
      echo "show_splash_clock = \${SHOW_SPLASH_CLOCK}"
      echo "hide_url = \${HIDE_URL}"
      echo "hide_overlay = \${HIDE_OVERLAY}"
      echo "volume = \${VOLUME}"
      echo "bg_music_volume = \${BG_MUSIC_VOLUME}"
      echo "screensaver_timeout = \${SCREENSAVER_TIMEOUT}"
      echo "splash_delay = \${SPLASH_DELAY}"
    fi

    if [[ "\${CUSTOM_SCORE_PHRASES}" == "True" ]]; then
      echo "low_score_phrases = \${LOW_SCORE_PHRASES}"
      echo "mid_score_phrases = \${MID_SCORE_PHRASES}"
      echo "high_score_phrases = \${HIGH_SCORE_PHRASES}"
    fi

    if [[ "\${CUSTOM_SERVER_SETTINGS}" == "True" ]]; then
      echo "normalize_audio = \${NORMALIZE_AUDIO}"
      echo "high_quality = \${HIGH_QUALITY}"
      echo "complete_transcode_before_play = \${COMPLETE_TRANSCODE_BEFORE_PLAY}"
      echo "cdg_pixel_scaling = \${CDG_PIXEL_SCALING}"
      echo "avsync = \${AVSYNC}"
      echo "limit_user_songs_by = \${LIMIT_USER_SONGS_BY}"
      echo "enable_fair_queue = \${ENABLE_FAIR_QUEUE}"
      echo "buffer_size = \${BUFFER_SIZE}"
      echo "browse_results_per_page = \${BROWSE_RESULTS_PER_PAGE}"
      if [[ -n "\${PREFERRED_LANGUAGE}" ]]; then
        echo "preferred_language = \${PREFERRED_LANGUAGE}"
      fi
    fi
  } > "\${CONFIG_FILE}"

  chown -R "\${APP_USER}:\${APP_USER}" "\${CONFIG_DIR}"
  chmod 644 "\${CONFIG_FILE}"
fi

echo "Creating systemd service..."
cat >/etc/systemd/system/pikaraoke.service <<EOL
[Unit]
Description=PiKaraoke
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=\${APP_USER}
Group=\${APP_USER}
WorkingDirectory=\${APP_HOME}
Environment=HOME=\${APP_HOME}
Environment=LANG=en_GB.UTF-8
Environment=LANGUAGE=en_GB:en
Environment=PATH=\${APP_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=\${APP_HOME}/.local/bin/pikaraoke --headless --port \${PORT} --download-path \${SONGS_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

echo "Enabling and starting service..."
systemctl daemon-reload
systemctl enable pikaraoke.service
systemctl restart pikaraoke.service

echo
echo "Install complete."
echo "Songs directory: \${SONGS_DIR}"
echo "Data directory: \${APP_HOME}"
echo "Main UI: http://<LXC-IP>:\${PORT}"
echo "Splash UI: http://<LXC-IP>:\${PORT}/splash"
EOF

chmod 755 "$TMP_INSTALLER"

# ---------------- Push installer and run ----------------
msg "Copying installer into container..."
pct push "$CTID" "$TMP_INSTALLER" /root/install-pikaraoke.sh
ok "Installer copied."

msg "Running PiKaraoke installer inside container..."
set +e
pct exec "$CTID" -- bash -lc "chmod +x /root/install-pikaraoke.sh && /root/install-pikaraoke.sh"
INSTALL_RC=$?
set -e

rm -f "$TMP_INSTALLER"

if [[ "$INSTALL_RC" -ne 0 ]]; then
  err "Installer failed inside container."
  if confirm "Destroy failed container $CTID?"; then
    cleanup_failed_ct "$CTID"
  fi
  exit "$INSTALL_RC"
fi

# ---------------- Final status ----------------
msg "Checking service status..."
pct exec "$CTID" -- systemctl status pikaraoke --no-pager || true

CT_IP="$(get_ct_ip "$CTID")"
if [[ -z "$CT_IP" ]]; then
  CT_IP="<unknown>"
fi

echo
ok "PiKaraoke deployment complete."
echo "Container ID:  $CTID"
echo "Hostname:      $HOSTNAME"
echo "Container IP:  $CT_IP"
echo
echo "Main UI:       http://${CT_IP}:${PORT}"
echo "Splash UI:     http://${CT_IP}:${PORT}/splash"
echo
echo "Songs folder inside CT: /mnt/pikaraoke-songs"
echo "Data folder inside CT:  /var/lib/pikaraoke"
echo "Tip: add a Proxmox bind mount to /mnt/pikaraoke-songs if you want songs stored outside the CT."
echo
echo "Useful commands:"
echo "  pct enter $CTID"
echo "  pct stop $CTID"
echo "  pct start $CTID"
echo "  pct exec $CTID -- systemctl status pikaraoke --no-pager"
