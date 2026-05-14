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

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "  hybridappliance bootstrap complete"
echo ""
echo "  Customer tag:    $CUSTOMER_TAG"
echo "  Hostname:        $(hostname)"
echo "  Tailscale IP:    ${TS_IP:-not-assigned}"
echo "  Docker version:  $(docker --version)"
echo ""
echo "  Next: open Coolify → Servers → + Add"
echo "        IP:    ${TS_IP:-<tailscale-ip>}"
echo "        User:  root"
echo "        Port:  22"
echo "        Private Key: select the Coolify deploy key"
echo "─────────────────────────────────────────────────────────────"
