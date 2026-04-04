#!/bin/sh
# Reference file — NOT sourced at runtime.
# The actual defaults are inlined in write-heat-params-master.sh and
# write-heat-params.sh. SHA256 checksum is downloaded automatically from
# the GitHub release (bootstrap.sha256 alongside the binary).
#
# CI updates RECONCILER_DEFAULT_VERSION in both write-heat-params scripts
# on each release.
#
# Current defaults:
RECONCILER_DEFAULT_VERSION="v1.0.0"
RECONCILER_DEFAULT_REPOSITORY="https://github.com/ventus-ag/magnum-bootstrap"
