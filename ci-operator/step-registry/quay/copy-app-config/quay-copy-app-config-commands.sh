#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG_SRC="ci-generator/config/config.yaml"

if [[ ! -s "${CONFIG_SRC}" ]]; then
  echo "ERROR: ${CONFIG_SRC} is missing or empty in the source checkout" >&2
  exit 1
fi

curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
  -o /tmp/yq && chmod +x /tmp/yq

config_tag="$(/tmp/yq eval 'tag' "${CONFIG_SRC}")"
if [[ "${config_tag}" != "!!map" ]]; then
  echo "ERROR: ${CONFIG_SRC} is not a YAML mapping (got tag '${config_tag}')" >&2
  exit 1
fi

cp "${CONFIG_SRC}" "${SHARED_DIR}/quay-app-config.yaml"

source_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
sha256="$(sha256sum "${CONFIG_SRC}" | awk '{print $1}')"

echo "source_sha=${source_sha}"
echo "sha256=${sha256}"

{
  echo "source_sha=${source_sha}"
  echo "sha256=${sha256}"
} > "${ARTIFACT_DIR}/quay-app-config-source.txt"
