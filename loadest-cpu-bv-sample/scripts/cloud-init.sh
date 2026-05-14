#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# =============================================================================
# Cloud-Init: Install sysbench + fio + OCI CLI
# Installs:
#   1. sysbench  — CPU/memory benchmarking tool
#   2. fio       — Storage I/O benchmarking tool
#   3. OCI CLI   — for pushing results to OCI Logging
# =============================================================================
set -euo pipefail

LOG="/var/log/cloud-init-tools.log"
SYSBENCH_MARKER="/tmp/.sysbench-ready"
FIO_MARKER="/tmp/.fio-ready"
OCI_CLI_MARKER="/tmp/.oci-cli-ready"
SYSBENCH_VERSION="1.0.20"
SYSBENCH_TARBALL_URL="https://github.com/akopytov/sysbench/archive/refs/tags/${SYSBENCH_VERSION}.tar.gz"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

log "=========================================="
log "Cloud-init tools installation starting..."
log "=========================================="

# =============================================================
# PART 1: Install sysbench
# =============================================================
log ""
log "--- Installing sysbench ---"

build_from_source() {
  log "Building sysbench ${SYSBENCH_VERSION} from source tarball..."

  local BUILD_DIR="/tmp/sysbench-build"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"

  log "Downloading ${SYSBENCH_TARBALL_URL}..."
  curl -fsSL "$SYSBENCH_TARBALL_URL" -o "$BUILD_DIR/sysbench.tar.gz" 2>>"$LOG"

  cd "$BUILD_DIR"
  tar xzf sysbench.tar.gz 2>>"$LOG"
  cd "sysbench-${SYSBENCH_VERSION}"

  log "Running autogen.sh..."
  ./autogen.sh >>"$LOG" 2>&1

  log "Running configure --without-mysql..."
  ./configure --without-mysql >>"$LOG" 2>&1

  log "Running make -j$(nproc)..."
  make -j"$(nproc)" >>"$LOG" 2>&1

  log "Running make install..."
  make install >>"$LOG" 2>&1

  echo "/usr/local/lib" > /etc/ld.so.conf.d/sysbench.conf
  ldconfig

  rm -rf "$BUILD_DIR"
  log "Source build complete."
}

install_sysbench_rpm() {
  log "Detected RPM-based OS (Oracle Linux / RHEL)..."

  if command -v dnf &>/dev/null; then
    local PKG_MGR="dnf"
  else
    local PKG_MGR="yum"
  fi

  $PKG_MGR install -y oracle-epel-release-el8 2>>"$LOG" \
    || $PKG_MGR install -y oracle-epel-release-el9 2>>"$LOG" \
    || $PKG_MGR install -y epel-release 2>>"$LOG" \
    || log "WARNING: Could not install EPEL release package."

  if $PKG_MGR install -y sysbench 2>>"$LOG"; then
    log "sysbench installed via package manager."
    return 0
  fi

  log "sysbench not available in package repos. Falling back to source build..."

  $PKG_MGR install -y \
    make automake autoconf libtool \
    pkgconfig libaio-devel openssl-devel \
    gcc gcc-c++ \
    curl tar gzip \
    2>>"$LOG"

  build_from_source
}

install_sysbench_deb() {
  log "Detected Debian-based OS (Ubuntu / Debian)..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -qq >>"$LOG" 2>&1

  if apt-get install -y sysbench >>"$LOG" 2>&1; then
    log "sysbench installed via apt."
    return 0
  fi

  log "sysbench not available via apt. Falling back to source build..."
  apt-get install -y \
    make automake autoconf libtool \
    pkg-config libaio-dev libssl-dev \
    gcc g++ \
    curl tar gzip \
    >>"$LOG" 2>&1

  build_from_source
}

if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
  install_sysbench_rpm
elif command -v apt-get &>/dev/null; then
  install_sysbench_deb
else
  log "ERROR: Unsupported OS — no dnf/yum/apt-get found."
  exit 1
fi

# Verify sysbench
SYSBENCH_BIN=""
if command -v sysbench &>/dev/null; then
  SYSBENCH_BIN="sysbench"
elif [ -x /usr/local/bin/sysbench ]; then
  SYSBENCH_BIN="/usr/local/bin/sysbench"
fi

if [ -n "$SYSBENCH_BIN" ]; then
  SYSBENCH_VER=$($SYSBENCH_BIN --version 2>&1)
  log "SUCCESS: $SYSBENCH_VER installed at $(which sysbench 2>/dev/null || echo $SYSBENCH_BIN)."
  echo "$SYSBENCH_VER" > "$SYSBENCH_MARKER"
  chmod 644 "$SYSBENCH_MARKER"

  log "Running sysbench smoke test..."
  if $SYSBENCH_BIN cpu --threads=1 --cpu-max-prime=1000 --time=1 run >>"$LOG" 2>&1; then
    log "Smoke test PASSED."
  else
    log "WARNING: Smoke test failed, but binary exists."
  fi
else
  log "ERROR: sysbench binary not found after installation."
  cat "$LOG"
  exit 1
fi

# =============================================================
# PART 2: Install fio
# =============================================================
log ""
log "--- Installing fio ---"

install_fio_rpm() {
  log "Installing fio via RPM package manager..."
  local PKG_MGR="dnf"
  if ! command -v dnf &>/dev/null; then
    PKG_MGR="yum"
  fi

  if $PKG_MGR install -y fio 2>>"$LOG"; then
    log "fio installed via package manager."
    return 0
  fi

  log "WARNING: Could not install fio via package manager."
  return 1
}

install_fio_deb() {
  log "Installing fio via apt..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >>"$LOG" 2>&1

  if apt-get install -y fio >>"$LOG" 2>&1; then
    log "fio installed via apt."
    return 0
  fi

  log "WARNING: Could not install fio via apt."
  return 1
}

if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
  install_fio_rpm
elif command -v apt-get &>/dev/null; then
  install_fio_deb
else
  log "WARNING: Cannot install fio — unsupported package manager."
fi

# Verify fio
if command -v fio &>/dev/null; then
  FIO_VER=$(fio --version 2>&1)
  log "SUCCESS: fio $FIO_VER installed at $(which fio)."
  echo "$FIO_VER" > "$FIO_MARKER"
  chmod 644 "$FIO_MARKER"

  log "Running fio smoke test..."
  if fio --name=smoke --rw=read --bs=4k --size=1M --runtime=1 --time_based --minimal >>"$LOG" 2>&1; then
    log "Smoke test PASSED."
  else
    log "WARNING: Smoke test failed, but binary exists."
  fi
else
  log "WARNING: fio not found after installation. FIO benchmarks will not be available."
fi

# =============================================================
# PART 3: Install OCI CLI
# =============================================================
log ""
log "--- Installing OCI CLI ---"

# Check if already installed
if command -v oci &>/dev/null; then
  OCI_VER=$(oci --version 2>&1)
  log "OCI CLI already installed: $OCI_VER"
  echo "$OCI_VER" > "$OCI_CLI_MARKER"
else
  log "OCI CLI not found. Installing via install script..."

  # Install python3 if not present (should be on OL8 but just in case)
  if ! command -v python3 &>/dev/null; then
    if command -v dnf &>/dev/null; then
      dnf install -y python3 2>>"$LOG"
    elif command -v apt-get &>/dev/null; then
      apt-get install -y python3 python3-venv 2>>"$LOG"
    fi
  fi

  # Download the install script first, then run it directly
  # (piping curl into bash fails in cloud-init due to getcwd issues)
  log "Downloading OCI CLI installer..."
  curl -fsSL https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh \
    -o /tmp/oci-cli-install.sh 2>>"$LOG"
  chmod +x /tmp/oci-cli-install.sh

  # Detect the default login user (opc on Oracle Linux, ubuntu on Ubuntu, etc.)
  DEFAULT_USER=""
  for u in opc ubuntu cloud-user ec2-user; do
    if id "$u" &>/dev/null; then
      DEFAULT_USER="$u"
      break
    fi
  done
  if [ -z "$DEFAULT_USER" ]; then
    DEFAULT_USER=$(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}' | head -1)
  fi
  DEFAULT_HOME=$(getent passwd "$DEFAULT_USER" | cut -d: -f6)

  log "Running OCI CLI installer for $DEFAULT_USER user..."
  cd "$DEFAULT_HOME"
  sudo -u "$DEFAULT_USER" bash /tmp/oci-cli-install.sh --accept-all-defaults >>"$LOG" 2>&1
  rm -f /tmp/oci-cli-install.sh

  # The installer puts it in ~/bin/oci for the default user
  # Also create a system-wide symlink so remote-exec can find it
  OCI_BIN=""
  if [ -x "$DEFAULT_HOME/bin/oci" ]; then
    OCI_BIN="$DEFAULT_HOME/bin/oci"
  elif [ -x "$DEFAULT_HOME/lib/oracle-cli/bin/oci" ]; then
    OCI_BIN="$DEFAULT_HOME/lib/oracle-cli/bin/oci"
  else
    # Search for it
    OCI_BIN=$(find "$DEFAULT_HOME" -name "oci" -type f -executable 2>/dev/null | head -1)
  fi

  if [ -n "$OCI_BIN" ] && [ -x "$OCI_BIN" ]; then
    # Create system-wide symlink
    ln -sf "$OCI_BIN" /usr/local/bin/oci
    log "Created symlink: /usr/local/bin/oci -> $OCI_BIN"

    OCI_VER=$(/usr/local/bin/oci --version 2>&1)
    log "SUCCESS: OCI CLI $OCI_VER installed."
    echo "$OCI_VER" > "$OCI_CLI_MARKER"
  else
    log "WARNING: OCI CLI installation completed but binary not found."
    log "Searched in $DEFAULT_HOME/bin and $DEFAULT_HOME/lib/oracle-cli/bin"
    log "Benchmark results will still be saved locally but not pushed to OCI Logging."
  fi
fi

chmod 644 "$OCI_CLI_MARKER" 2>/dev/null || true

# =============================================================
# Done
# =============================================================
log ""
log "=========================================="
log "Cloud-init tools installation complete."
log "  sysbench: $(cat $SYSBENCH_MARKER 2>/dev/null || echo 'NOT INSTALLED')"
log "  fio:      $(cat $FIO_MARKER 2>/dev/null || echo 'NOT INSTALLED')"
log "  OCI CLI:  $(cat $OCI_CLI_MARKER 2>/dev/null || echo 'NOT INSTALLED')"
log "=========================================="
