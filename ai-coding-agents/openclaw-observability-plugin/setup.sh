#!/usr/bin/env bash
#
# Install the openclaw-observability-plugin, OTel Collector Contrib, and wire
# everything to a Dynatrace OTLP endpoint.
#
# Usage:
#   ./setup.sh https://<env-id>.live.dynatrace.com/api/v2/otlp <DT_API_TOKEN>
#
# The token must have the openTelemetryTrace.ingest, metrics.ingest, and logs.ingest scopes.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <dynatrace-otlp-endpoint> <dynatrace-api-token>" >&2
  exit 64
fi

OTLP_ENDPOINT="$1"
DT_TOKEN="$2"

PLUGIN_REPO="https://github.com/henrikrexed/openclaw-observability-plugin.git"
PLUGIN_ID="otel-observability"
EXTENSIONS_DIR="${HOME}/.openclaw/extensions"
PLUGIN_DIR="${EXTENSIONS_DIR}/${PLUGIN_ID}"
ENV_FILE="${HOME}/.openclaw/.env"
COLLECTOR_CONFIG_SRC="$(cd "$(dirname "$0")" && pwd)/otel-collector-config.yaml"
COLLECTOR_CONFIG_DIR="/etc/otelcol-contrib"
COLLECTOR_CONFIG_DST="${COLLECTOR_CONFIG_DIR}/config.yaml"
COLLECTOR_ENV_DST="${COLLECTOR_CONFIG_DIR}/otelcol-env"

# ─────────────────────────────────────────────────────────────────────
# 1. Install OTel Collector Contrib if not already present
# ─────────────────────────────────────────────────────────────────────
if command -v otelcol-contrib &>/dev/null; then
  echo "OTel Collector Contrib already installed: $(otelcol-contrib --version 2>/dev/null || echo 'version unknown')"
elif systemctl is-active --quiet otelcol-contrib 2>/dev/null; then
  echo "OTel Collector Contrib service is running."
else
  echo "Installing latest OTel Collector Contrib..."
  ARCH=$(uname -m)
  case "${ARCH}" in
    x86_64)  GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
    *)       echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
  esac

  OTEL_VERSION=$(curl -sfL "https://api.github.com/repos/open-telemetry/opentelemetry-collector-releases/releases/latest" \
    | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')

  if [[ -z "${OTEL_VERSION}" ]]; then
    echo "Could not determine latest otelcol-contrib version." >&2
    exit 1
  fi

  PKG_NAME="otelcol-contrib_${OTEL_VERSION}_linux_${GOARCH}.deb"
  DOWNLOAD_URL="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/${PKG_NAME}"

  TMPDIR=$(mktemp -d)
  echo "  Downloading v${OTEL_VERSION} for ${GOARCH}..."
  curl -sfL "${DOWNLOAD_URL}" -o "${TMPDIR}/${PKG_NAME}"
  sudo dpkg -i "${TMPDIR}/${PKG_NAME}" || sudo apt-get install -f -y
  rm -rf "${TMPDIR}"
  echo "OTel Collector Contrib v${OTEL_VERSION} installed."
fi

# ─────────────────────────────────────────────────────────────────────
# 2. Deploy collector config
# ─────────────────────────────────────────────────────────────────────
if [[ ! -f "${COLLECTOR_CONFIG_SRC}" ]]; then
  echo "WARNING: ${COLLECTOR_CONFIG_SRC} not found. Downloading from plugin repo..."
  TMPDIR=$(mktemp -d)
  curl -sfL "https://raw.githubusercontent.com/henrikrexed/openclaw-observability-plugin/main/collector/otel-collector-config.yaml" \
    -o "${TMPDIR}/otel-collector-config.yaml"
  COLLECTOR_CONFIG_SRC="${TMPDIR}/otel-collector-config.yaml"
fi

sudo mkdir -p "${COLLECTOR_CONFIG_DIR}"
sudo cp "${COLLECTOR_CONFIG_SRC}" "${COLLECTOR_CONFIG_DST}"

# Write the environment file for the collector systemd unit.
# The collector config reads ${env:DT_ENDPOINT} and ${env:DT_API_TOKEN}.
sudo tee "${COLLECTOR_ENV_DST}" >/dev/null <<ENVEOF
DT_ENDPOINT="${OTLP_ENDPOINT}"
DT_API_TOKEN="${DT_TOKEN}"
ENVEOF

# Ensure the systemd unit loads the env file.
# otelcol-contrib deb installs /etc/otelcol-contrib/config.yaml by default.
# Override the unit to also pass the env file.
sudo mkdir -p /etc/systemd/system/otelcol-contrib.service.d
sudo tee /etc/systemd/system/otelcol-contrib.service.d/env.conf >/dev/null <<EOF
[Service]
EnvironmentFile=${COLLECTOR_ENV_DST}
EOF

sudo systemctl daemon-reload
sudo systemctl enable otelcol-contrib
sudo systemctl restart otelcol-contrib
echo "Collector configured and restarted."

# ─────────────────────────────────────────────────────────────────────
# 3. Clone or update the plugin into ~/.openclaw/extensions/otel-observability
# ─────────────────────────────────────────────────────────────────────
mkdir -p "${EXTENSIONS_DIR}"
if [[ -d "${PLUGIN_DIR}/.git" ]]; then
  echo "Plugin already cloned at ${PLUGIN_DIR} — pulling latest."
  git -C "${PLUGIN_DIR}" pull --ff-only
else
  echo "Cloning ${PLUGIN_REPO} into ${PLUGIN_DIR}"
  git clone "${PLUGIN_REPO}" "${PLUGIN_DIR}"
fi

# 4. Install plugin dependencies
( cd "${PLUGIN_DIR}" && npm install --omit=dev )

# ─────────────────────────────────────────────────────────────────────
# 5. Configure OpenClaw — point at local collector, not Dynatrace directly
# ─────────────────────────────────────────────────────────────────────
openclaw config set diagnostics.enabled true
openclaw config set diagnostics.otel.enabled true
openclaw config set diagnostics.otel.traces true
openclaw config set diagnostics.otel.metrics true
openclaw config set diagnostics.otel.logs true
openclaw config set diagnostics.otel.protocol http/protobuf
openclaw config set diagnostics.otel.endpoint "http://localhost:4318"
openclaw config set diagnostics.otel.serviceName openclaw-gateway

# Register the plugin entry. The entry id MUST be `otel-observability`
# (matches the plugin manifest) — using the repo name will silently fail to load.
openclaw config set "plugins.load.paths" "[\"${PLUGIN_DIR}\"]"
openclaw config set "plugins.entries.otel-observability.enabled" true

# ─────────────────────────────────────────────────────────────────────
# 6. Delta temporality env var for OpenClaw
# ─────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "${ENV_FILE}")"
if grep -q '^OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=' "${ENV_FILE}" 2>/dev/null; then
  sed -i 's|^OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=.*|OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta|' "${ENV_FILE}"
else
  printf 'OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta\n' >> "${ENV_FILE}"
fi

# ─────────────────────────────────────────────────────────────────────
# 7. Clear the TS plugin loader cache and restart the gateway
# ─────────────────────────────────────────────────────────────────────
rm -rf /tmp/jiti
if systemctl --user is-enabled --quiet openclaw-gateway 2>/dev/null; then
  systemctl --user restart openclaw-gateway
  echo "OpenClaw gateway restarted."
else
  echo "Service openclaw-gateway not managed by systemd --user; restart manually."
fi

cat <<EOF

Setup complete.
  Plugin     : ${PLUGIN_DIR}
  Collector  : /etc/otelcol-contrib/config.yaml
  DT Endpoint: ${OTLP_ENDPOINT}
  Env file   : ${ENV_FILE}

Data flow:
  OpenClaw plugin → OTel Collector (localhost:4318) → Dynatrace

Next steps:
  - Tail the gateway log for [otel] hook-registration lines:
      journalctl --user -u openclaw-gateway -f | grep -E '\[otel\]'
  - Verify collector is receiving data:
      journalctl -u otelcol-contrib -f | grep -E '(traces|metrics|logs)'
  - Send a real message through OpenClaw and verify a connected
    'openclaw.request' -> 'openclaw.agent.turn' -> 'tool.*' trace
    appears in Dynatrace under service.name = openclaw-gateway.
EOF
