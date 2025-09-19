#!/bin/bash

# Setup script to install and configure apex and verl
# This script will automatically answer 'yes' to all prompts

set -e  # Exit on any error

echo "Starting setup process..."

# Install CUDA 12.9 first
echo "Installing CUDA 12.9..."
wget wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-ubuntu2404.pin
mv cuda-ubuntu2404.pin /etc/apt/preferences.d/cuda-repository-pin-600
wget https://developer.download.nvidia.com/compute/cuda/12.9.0/local_installers/cuda-repo-ubuntu2404-12-9-local_12.9.0-575.51.03-1_amd64.deb
dpkg -i cuda-repo-ubuntu2404-12-9-local_12.9.0-575.51.03-1_amd64.deb
cp /var/cuda-repo-ubuntu2404-12-9-local/cuda-*-keyring.gpg /usr/share/keyrings/
apt-get update
apt-get -y install cuda-toolkit-12-9

# Install/upgrade PyTorch to latest version with CUDA 12.9 support
echo "Upgrading PyTorch to latest version..."
pip3 uninstall -y torch torchvision torchaudio || true
pip3 install torch torchvision --index-url https://download.pytorch.org/whl/cu129

# Update system packages with automatic yes
echo "Updating package lists..."
apt update -y

echo "Upgrading packages..."
apt upgrade -y

echo "Performing distribution upgrade..."
apt dist-upgrade -y

# Install NVIDIA apex
echo "Cloning and installing NVIDIA apex..."
git clone https://github.com/NVIDIA/apex.git
cd apex
MAX_JOB=32 pip install -v --disable-pip-version-check --no-cache-dir --no-build-isolation --config-settings "--build-option=--cpp_ext" --config-settings "--build-option=--cuda_ext" ./
cd ..

# Install verl
echo "Cloning and installing verl..."
git clone https://github.com/volcengine/verl.git
cd verl
pip install --no-deps -e .
USE_MEGATRON=0 bash scripts/install_vllm_sglang_mcore.sh
cd ..

echo "Setup completed successfully!"

# Install requirements from verl folder
echo "Installing requirements from verl/requirements.txt..."
cd verl
pip install -r requirements.txt
cd ..

# -------- Additional Setup: Jupyter Configuration --------

# -------- Helpers --------
prompt_default() {
  local prompt="$1" default="$2" var
  read -rp "$prompt [$default]: " var
  echo "${var:-$default}"
}
log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[!] %s\033[0m\n" "$*"; }

SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# -------- Prompt for inputs (with defaults) --------
JUPYTER_PORT=$(prompt_default "Jupyter port" "5000")

# -------- Install nano and tmux --------
log "Installing nano & tmux via apt…"
$SUDO apt update -y
$SUDO apt install -y nano tmux

# -------- Install Jupyter --------
log "Installing Jupyter packages with pip…"
pip install jupyter notebook jupyterlab

# -------- Configure Jupyter for remote use --------
log "Generating and writing Jupyter config…"
jupyter notebook --generate-config >/dev/null 2>&1 || true
CONFIG="${HOME}/.jupyter/jupyter_notebook_config.py"
cat > "${CONFIG}" <<EOF
c = get_config()

# Modern Jupyter (ServerApp)
c.ServerApp.ip = '0.0.0.0'
c.ServerApp.port = ${JUPYTER_PORT}
c.ServerApp.open_browser = False
c.ServerApp.allow_remote_access = True
c.ServerApp.allow_origin = '*'

# Backward-compat (NotebookApp)
c.NotebookApp.ip = '0.0.0.0'
c.NotebookApp.port = ${JUPYTER_PORT}
c.NotebookApp.open_browser = False
c.NotebookApp.allow_remote_access = True
c.NotebookApp.allow_origin = '*'
EOF

# -------- Launch Jupyter Lab inside tmux --------
SESSION="jupyter_session"
log "Starting Jupyter Lab in tmux session '${SESSION}' on port ${JUPYTER_PORT}…"
tmux has-session -t "${SESSION}" 2>/dev/null && tmux kill-session -t "${SESSION}" || true

# Launch Jupyter Lab in tmux
tmux new-session -d -s "${SESSION}" \
  "bash -lc 'exec jupyter lab --port=${JUPYTER_PORT} --no-browser --allow-root'"

# -------- Poll for server & print token --------
log "Fetching Jupyter server token…"

# Helper to query server list
server_list() { jupyter server list 2>/dev/null || true; }

TOKEN_LINE=""
for i in $(seq 1 90); do
  TOKEN_LINE=$(server_list | awk -v p=":${JUPYTER_PORT}/" '$0 ~ p {print; exit}')
  if [[ -n "$TOKEN_LINE" ]]; then
    break
  fi
  sleep 1
done

TOKEN=""
if [[ -n "$TOKEN_LINE" ]]; then
  # Extract token if present
  TOKEN=$(printf "%s" "$TOKEN_LINE" | sed -n 's/.*token=\([^[:space:]]*\).*/\1/p')
fi

# -------- Final info + diagnostics --------
cat <<INFO

========================================================
✅ Complete setup finished.

Jupyter:     running in tmux session '${SESSION}' on port ${JUPYTER_PORT}

Attach to the session:
  tmux attach -t ${SESSION}

Set a password (optional, one-time):
  tmux new-window -t ${SESSION} -n setpass "jupyter lab password"

List running servers:
  tmux new-window -t ${SESSION} -n servers "jupyter server list"
  
SSH port-forward from your laptop:
  ssh -N -L ${JUPYTER_PORT}:localhost:${JUPYTER_PORT} user@your-server
========================================================
INFO

if [[ -n "$TOKEN_LINE" ]]; then
  echo "Server URL (raw):"
  echo "  $TOKEN_LINE"
  if [[ -n "$TOKEN" ]]; then
    echo
    echo "Open in browser after SSH port-forwarding:"
    echo "  http://localhost:${JUPYTER_PORT}/?token=${TOKEN}"
  fi
else
  err "Could not retrieve the Jupyter URL yet (port ${JUPYTER_PORT})."

  echo -e "\nDiagnostics:"
  echo "1) tmux sessions:"
  tmux ls || true

  echo -e "\n2) Last 80 lines from the Jupyter tmux pane:"
  tmux capture-pane -t "${SESSION}:.+0" -p -S -80 || true

  echo -e "\n3) Manual checks you can run:"
  echo "   tmux attach -t ${SESSION}"
  echo "   jupyter server list"
fi