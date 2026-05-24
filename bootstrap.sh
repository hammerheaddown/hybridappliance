#!/usr/bin/env bash
# hybridappliance bootstrap — provisions a fresh Ubuntu/Debian box as a Coolify deploy target.
#
# Usage (on the fresh appliance, as root):
#   TS_AUTHKEY=tskey-auth-XXX CUSTOMER_TAG=wtom \
#     curl -fsSL https://raw.githubusercontent.com/hammerheaddown/hybridappliance/main/bootstrap.sh | sudo -E bash
#
# Required env vars:
#   TS_AUTHKEY    Tailscale pre-authorized auth key (tskey-auth-...)
# Optional:
#   CUSTOMER_TAG  Short customer identifier (used as hostname). Default: appliance-<random>
#
# What it does:
#   1. Sets hostname
#   2. Installs Tailscale and auto-joins your tailnet via auth key
#   3. Installs Docker (Coolify's deploy mechanism)
#   4. Adds Coolify's SSH public key to /root/.ssh/authorized_keys
#   5. Prints the Tailscale IP so you can add the box as a Coolify Server

set -euo pipefail

# ─── Hardcoded values ──────────────────────────────────────────────────────
# Coolify's deploy SSH public key — same key used for every appliance.
# To rotate: regenerate in Coolify (Keys & Tokens → Private Keys), update value below, push.
COOLIFY_SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHCFzHnuScyckqpn9MLwY+n43BdnjxVywZ8bOYo6C6G4 coolify-deploy"

# ─── Sanity checks ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "[hybridappliance] ERROR: must run as root. Try:  curl ... | sudo -E bash" >&2
  exit 1
fi

if [[ -z "${TS_AUTHKEY:-}" ]]; then
  echo "[hybridappliance] ERROR: TS_AUTHKEY env var is required." >&2
  echo "Usage: TS_AUTHKEY=tskey-auth-... [CUSTOMER_TAG=wtom] curl ... | sudo -E bash" >&2
  exit 1
fi

CUSTOMER_TAG="${CUSTOMER_TAG:-appliance-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)}"

echo "[hybridappliance] Provisioning as: $CUSTOMER_TAG"

# ─── 1. Hostname ───────────────────────────────────────────────────────────
hostnamectl set-hostname "$CUSTOMER_TAG"

# ─── 2. Tailscale ──────────────────────────────────────────────────────────
echo "[hybridappliance] Installing Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "[hybridappliance] Bringing Tailscale up..."
tailscale up \
  --authkey="$TS_AUTHKEY" \
  --hostname="$CUSTOMER_TAG" \
  --accept-routes \
  --ssh

sleep 3
TS_IP="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$TS_IP" ]]; then
  echo "[hybridappliance] WARNING: Tailscale didn't return an IP. Check 'tailscale status' manually." >&2
fi

# ─── 2b. Tailscale Serve (HTTPS via MagicDNS + Let's Encrypt) ─────────────
# Pre-configure HTTPS proxying so as soon as Coolify deploys the
# HybridPlayout app (on :8100) and noVNC is running (on :6080), they're
# reachable over HTTPS at https://<hostname>.<tailnet>.ts.net with real
# certs. Until the upstreams come up, these endpoints return 502 — harmless.
#
# Requires HTTPS to be enabled in the Tailscale admin console
# (https://login.tailscale.com/admin/dns → "HTTPS Certificates" → Enable).
# Set TS_SKIP_SERVE=1 in env to bypass this step.
if [[ "${TS_SKIP_SERVE:-}" != "1" ]]; then
  echo "[hybridappliance] Configuring Tailscale Serve for HTTPS..."
  # Admin / player kiosk → HTTPS 443 → app on 8100
  tailscale serve --bg --https=443 http://localhost:8100 || \
    echo "[hybridappliance] WARNING: tailscale serve 443→8100 failed. Run manually after install." >&2
  # noVNC → HTTPS 6443 → noVNC websockify on 6080
  tailscale serve --bg --https=6443 http://localhost:6080 || \
    echo "[hybridappliance] WARNING: tailscale serve 6443→6080 failed. Run manually after install." >&2
fi

# ─── 3. Docker ─────────────────────────────────────────────────────────────
echo "[hybridappliance] Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# ─── 4. Coolify SSH key ────────────────────────────────────────────────────
echo "[hybridappliance] Installing Coolify SSH key..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if ! grep -qF "$COOLIFY_SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
  echo "$COOLIFY_SSH_PUBKEY" >> /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys

# ─── 5. noVNC (remote-view the kiosk's actual screen via REMOTE tab) ──────
# Lets the operator see the TV's literal output through Tailscale-served
# HTTPS (port 6443 → 6080). Requires a graphical session on the box
# (kiosk autologin + Chromium fullscreen — separate setup).
#
# Set NOVNC_SKIP=1 in env to bypass this step (e.g. headless servers
# that won't ever run the kiosk locally).
if [[ "${NOVNC_SKIP:-}" != "1" ]]; then
  echo "[hybridappliance] Installing noVNC + x11vnc + websockify..."
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    novnc x11vnc websockify >/dev/null

  # Systemd unit that attaches noVNC to whatever X session :0 is running.
  # x11vnc finds the .Xauthority cookie automatically via -auth guess.
  # Websockify bridges browser WebSocket → x11vnc RFB on localhost:5900.
  cat > /etc/systemd/system/hybridplayout-novnc.service <<'UNIT'
[Unit]
Description=HybridPlayout noVNC (browser-facing on :6080)
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
# x11vnc wants a DISPLAY + Xauthority; this works for the autologin user's
# session. -shared so multiple operators can connect; -forever to survive
# disconnects; -nopw because access is gated at the Tailscale + admin layer.
ExecStartPre=/bin/bash -c 'for i in {1..30}; do [ -e /tmp/.X11-unix/X0 ] && exit 0; sleep 2; done; exit 1'
ExecStart=/usr/bin/x11vnc -display :0 -auth guess -forever -shared -nopw -rfbport 5900 -quiet
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
UNIT

  cat > /etc/systemd/system/hybridplayout-websockify.service <<'UNIT'
[Unit]
Description=HybridPlayout websockify bridge (browser → x11vnc)
After=hybridplayout-novnc.service
Requires=hybridplayout-novnc.service

[Service]
Type=simple
ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 6080 localhost:5900
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now hybridplayout-novnc.service     || true
  systemctl enable --now hybridplayout-websockify.service || true
  echo "[hybridappliance] noVNC services installed (will start with the next graphical session)."
fi

# ─── Summary ───────────────────────────────────────────────────────────────
TS_FQDN="$(tailscale status --json 2>/dev/null | grep -oE '"DNSName":\s*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)\.".*/\1/' || true)"
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "  hybridappliance bootstrap complete"
echo ""
echo "  Customer tag:    $CUSTOMER_TAG"
echo "  Hostname:        $(hostname)"
echo "  Tailscale IP:    ${TS_IP:-not-assigned}"
echo "  Tailscale FQDN:  ${TS_FQDN:-<check 'tailscale status'>}"
echo "  Docker version:  $(docker --version)"
echo ""
echo "  Next: open Coolify → Servers → + Add"
echo "        IP:    ${TS_IP:-<tailscale-ip>}"
echo "        User:  root"
echo "        Port:  22"
echo "        Private Key: select the Coolify deploy key"
echo ""
echo "  After Coolify deploys the HybridPlayout app, it'll be at:"
echo "    Admin:  https://${TS_FQDN:-<fqdn>}/admin.html"
echo "    Kiosk:  https://${TS_FQDN:-<fqdn>}/player.html"
echo "    VNC:    https://${TS_FQDN:-<fqdn>}:6443/vnc.html  (after noVNC install)"
echo "─────────────────────────────────────────────────────────────"
