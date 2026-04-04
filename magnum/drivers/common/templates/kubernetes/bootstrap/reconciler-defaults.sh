#!/bin/sh
# Default reconciler configuration.
# These values are used when the Heat template does not provide explicit
# reconciler settings. On each release, CI updates the version, URL, and
# checksum below.
#
# To pin a specific version, set these in the Heat template parameters:
#   reconciler_version, reconciler_binary_url, reconciler_binary_url_sha256

RECONCILER_DEFAULT_REPOSITORY="https://github.com/ventus-ag/magnum-bootstrap"
RECONCILER_DEFAULT_VERSION="v1.0.0"
RECONCILER_DEFAULT_BINARY_URL="${RECONCILER_DEFAULT_REPOSITORY}/releases/download/${RECONCILER_DEFAULT_VERSION}/bootstrap"
RECONCILER_DEFAULT_BINARY_URL_SHA256=""

# Apply defaults if not set by Heat template.
RECONCILER_VERSION="${RECONCILER_VERSION:-${RECONCILER_DEFAULT_VERSION}}"
RECONCILER_BINARY_URL="${RECONCILER_BINARY_URL:-${RECONCILER_DEFAULT_BINARY_URL}}"
RECONCILER_BINARY_URL_SHA256="${RECONCILER_BINARY_URL_SHA256:-${RECONCILER_DEFAULT_BINARY_URL_SHA256}}"
