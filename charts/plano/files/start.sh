#!/bin/bash
# Starts Plano without the image's supervisord setup, so that it runs as non-root
# on a read-only root filesystem and needs no internet access at startup.
# Same steps as the image: render the Envoy and Plano configs from plano_config.yaml,
# substitute $VARS from the environment, then run brightstaff and Envoy.
set -euo pipefail

CONFIG=${PLANO_CONFIG_FILE:-/etc/plano/plano_config.yaml}
RUN=${PLANO_RUN_DIR:-/tmp/plano}
mkdir -p "$RUN"
cd /app

# The image runs this with `uv run`, which downloads Python packages from PyPI on
# every start. The same packages are installed in the image's system Python.
if ! PLANO_CONFIG_FILE=$CONFIG \
     PLANO_CONFIG_FILE_RENDERED=$RUN/plano_config_rendered.yaml \
     ENVOY_CONFIG_FILE_RENDERED=$RUN/envoy.rendered.yaml \
     python -m planoai.config_generator > "$RUN/config_generator.log" 2>&1; then
  # On failure the log holds the error, not the rendered config.
  cat "$RUN/config_generator.log"
  echo "[plano] $CONFIG is invalid, see the error above" >&2
  exit 1
fi

envsubst < "$RUN/plano_config_rendered.yaml" > "$RUN/plano_config.yaml"

# Envoy's admin API returns the full config, provider API keys included, and the
# image binds it to all interfaces. Keep it on localhost unless asked otherwise.
# Access logs go to stdout instead of files that are never rotated.
admin_address=127.0.0.1
[ "${PLANO_ENVOY_ADMIN_ALL_INTERFACES:-false}" = "true" ] && admin_address=0.0.0.0
envsubst < "$RUN/envoy.rendered.yaml" | sed \
  -e "s/address: 0\.0\.0\.0, port_value: 9901 }/address: $admin_address, port_value: 9901 }/" \
  -e 's#path: "/var/log/access_[a-z_]*\.log"#path: "/dev/stdout"#' \
  > "$RUN/envoy.yaml"
if ! grep -q "address: $admin_address, port_value: 9901 }" "$RUN/envoy.yaml"; then
  echo "[plano] could not set the Envoy admin address; this Plano version is not supported by the chart" >&2
  exit 1
fi
rm -f "$RUN/plano_config_rendered.yaml" "$RUN/envoy.rendered.yaml"

PLANO_CONFIG_PATH_RENDERED=$RUN/plano_config.yaml RUST_LOG=${LOG_LEVEL:-info} \
  /app/brightstaff &
brightstaff=$!
# Envoy starts one worker per CPU of the node, not of the container, and every
# worker loads the WASM filters. PLANO_ENVOY_CONCURRENCY caps the workers.
envoy -c "$RUN/envoy.yaml" --component-log-level "wasm:${LOG_LEVEL:-info}" \
  ${PLANO_ENVOY_CONCURRENCY:+--concurrency "$PLANO_ENVOY_CONCURRENCY"} \
  --log-format '[%Y-%m-%d %T.%e][%l] %v' &
envoy=$!

trap 'kill -TERM "$brightstaff" "$envoy" 2>/dev/null || true' TERM INT

# Exit as soon as either process stops, so Kubernetes restarts the container.
set +e
wait -n "$brightstaff" "$envoy"
status=$?
kill -TERM "$brightstaff" "$envoy" 2>/dev/null
wait
echo "[plano] stopped (exit status $status)"
exit "$status"
