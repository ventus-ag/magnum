#!/bin/bash

set -eu

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"
launcher_path="/usr/local/bin/magnum-reconcile-launcher"

echo "Installing reconciler launcher: ${launcher_path}"

cat <<'EOF' | $ssh_cmd "cat > '${launcher_path}.tmp'"
#!/bin/bash

set -euo pipefail

mode="${1:-run-once}"
shift || true

heat_params_file="/etc/sysconfig/heat-params"
cache_root="/opt/magnum-reconciler"
lock_file="/var/lib/magnum/reconciler.lock"
result_file="/var/lib/magnum/reconciler-last-run.json"
log_file="/var/log/magnum-reconcile.log"
state_file="/var/lib/magnum/reconciler-state.json"
run_state_file="/var/lib/magnum/reconciler-run.json"
state_backup_dir="/var/lib/magnum/reconciler-state-backups"
pulumi_state_root="/var/lib/magnum/pulumi"
pulumi_backup_dir="/var/lib/magnum/pulumi-backups"
work_dir="/var/lib/magnum"
binary_name="bootstrap"
default_repository_url="https://github.com/ventus-ag/magnum-bootstrap"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

mkdir -p \
    "${cache_root}" \
    "${work_dir}" \
    "$(dirname "${log_file}")" \
    "${state_backup_dir}" \
    "${pulumi_state_root}" \
    "${pulumi_backup_dir}"

touch "${log_file}"
chmod 600 "${log_file}"

if [ -f "${heat_params_file}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${heat_params_file}"
    set +a
fi

version="${RECONCILER_VERSION:-}"
repository_url="${RECONCILER_REPOSITORY_URL:-${default_repository_url}}"
binary_url="${RECONCILER_BINARY_URL:-}"
lock_timeout_seconds="${RECONCILER_LOCK_TIMEOUT_SECONDS:-900}"

if [ -z "${binary_url}" ] && [ -n "${version}" ]; then
    binary_url="${repository_url}/releases/download/${version}/bootstrap"
fi

if [ -z "${version}" ] || [ -z "${binary_url}" ]; then
    log "Reconciler is not configured in ${heat_params_file}, skipping ${mode}"
    exit 0
fi

exec 9>"${lock_file}"
if [ "${mode}" = "run-periodic" ]; then
    if ! flock -n 9; then
        log "Reconcile lock is busy, skipping periodic run"
        exit 0
    fi
else
    if ! flock -n 9; then
        log "Reconcile lock is busy (another run is active), waiting up to ${lock_timeout_seconds}s..."
        if ! flock -w "${lock_timeout_seconds}" 9; then
            log "ERROR: Timed out waiting for reconcile lock after ${lock_timeout_seconds}s"
            exit 1
        fi
        log "Lock acquired after wait"
    fi
fi

binary_dir="${cache_root}/${version}"
binary_path="${binary_dir}/${binary_name}"
sha256_url="${binary_url}.sha256"

# Re-download if the binary is missing OR if the previous run failed
# (binary might be corrupt or incomplete).
need_download=false
binary_url_sha256=""
if [ ! -x "${binary_path}" ]; then
    need_download=true
elif [ -f "${result_file}" ]; then
    last_status=$(grep -o '"status":"[^"]*"' "${result_file}" 2>/dev/null | head -1 | cut -d'"' -f4) || true
    if [ "${last_status}" = "failed" ]; then
        log "Previous run failed, re-downloading binary"
        rm -rf "${binary_dir}"
        need_download=true
    fi
fi

if [ "${need_download}" = "false" ]; then
    log "Fetching checksum from ${sha256_url}"
    binary_url_sha256=$(curl -fsSL "${sha256_url}" 2>/dev/null | awk '{print $1}') || true
    if [ -n "${binary_url_sha256}" ]; then
        current_binary_sha256=$(sha256sum "${binary_path}" | awk '{print $1}')
        if [ "${current_binary_sha256}" != "${binary_url_sha256}" ]; then
            log "Cached binary checksum differs from release checksum, re-downloading reconciler"
            rm -rf "${binary_dir}"
            need_download=true
        fi
    else
        log "Release checksum fetch failed, keeping cached reconciler binary"
    fi
fi

if [ "${need_download}" = "true" ]; then
    tmp_binary="$(mktemp)"
    trap 'rm -f "${tmp_binary}"' EXIT

    log "Downloading reconciler binary version=${version} url=${binary_url}"
    if [ -n "${repository_url}" ]; then
        log "Reconciler repository ${repository_url}"
    fi
    curl -fsSL "${binary_url}" -o "${tmp_binary}"
    # Download SHA256 checksum from the release and verify.
    if [ -z "${binary_url_sha256}" ]; then
        log "Fetching checksum from ${sha256_url}"
        binary_url_sha256=$(curl -fsSL "${sha256_url}" 2>/dev/null | awk '{print $1}') || true
    fi
    if [ -n "${binary_url_sha256}" ]; then
        printf '%s  %s\n' "${binary_url_sha256}" "${tmp_binary}" | sha256sum -c -
    else
        log "WARNING: could not fetch SHA256 checksum, skipping verification"
    fi

    rm -rf "${binary_dir}.tmp" "${binary_dir}"
    mkdir -p "${binary_dir}.tmp"

    mv "${tmp_binary}" "${binary_dir}.tmp/${binary_name}"
    chmod 755 "${binary_dir}.tmp/${binary_name}"

    mv "${binary_dir}.tmp" "${binary_dir}"
    trap - EXIT
    rm -f "${tmp_binary}"
fi

if [ ! -x "${binary_path}" ]; then
    log "Reconciler binary is not executable: ${binary_path}"
    exit 1
fi

export MAGNUM_RECONCILE_MODE="${mode}"
export MAGNUM_RECONCILE_RESULT_FILE="${result_file}"
export MAGNUM_RECONCILE_LOG_FILE="${log_file}"
export MAGNUM_RECONCILE_HEAT_PARAMS_FILE="${heat_params_file}"
export MAGNUM_RECONCILE_STATE_FILE="${state_file}"
export MAGNUM_RECONCILE_RUN_STATE_FILE="${run_state_file}"
export MAGNUM_RECONCILE_STATE_BACKUP_DIR="${state_backup_dir}"
export MAGNUM_PULUMI_BACKEND_DIR="${pulumi_state_root}"
export MAGNUM_PULUMI_BACKEND_URL="file://${pulumi_state_root}"
export MAGNUM_PULUMI_BACKUP_DIR="${pulumi_backup_dir}"

log "Starting reconciler binary=${binary_path} mode=${mode}"
"${binary_path}" "${mode}" "$@"
rc=$?

log "Reconciler finished rc=${rc} mode=${mode}"
exit "${rc}"
EOF

$ssh_cmd mv "${launcher_path}.tmp" "${launcher_path}"
$ssh_cmd chown root:root "${launcher_path}"
$ssh_cmd chmod 755 "${launcher_path}"
