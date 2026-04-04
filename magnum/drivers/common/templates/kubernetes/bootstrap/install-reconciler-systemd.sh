#!/bin/bash

set -eu

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"
heat_params_file="/etc/sysconfig/heat-params"
run_interval="${RECONCILER_RUN_INTERVAL:-}"

if [ -z "${run_interval}" ]; then
    run_interval="$($ssh_cmd "if [ -f '${heat_params_file}' ]; then set -a; . '${heat_params_file}'; set +a; fi; printf '%s' \"\${RECONCILER_RUN_INTERVAL:-}\"" 2>/dev/null || true)"
fi

run_interval="${run_interval:-120min}"

echo "Installing reconciler systemd units"

cat <<'EOF' | $ssh_cmd "cat > /etc/systemd/system/magnum-reconcile.service.tmp"
[Unit]
Description=Magnum Reconcile
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/magnum-reconcile-launcher run-once
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' | $ssh_cmd "cat > /etc/systemd/system/magnum-reconcile-periodic.service.tmp"
[Unit]
Description=Magnum Reconcile Periodic
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/magnum-reconcile-launcher run-periodic
User=root
Group=root
EOF

cat <<EOF | $ssh_cmd "cat > /etc/systemd/system/magnum-reconcile.timer.tmp"
[Unit]
Description=Run Magnum Reconcile Periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=${run_interval}
Unit=magnum-reconcile-periodic.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

for unit in \
    /etc/systemd/system/magnum-reconcile.service \
    /etc/systemd/system/magnum-reconcile-periodic.service \
    /etc/systemd/system/magnum-reconcile.timer; do
    $ssh_cmd mv "${unit}.tmp" "${unit}"
    $ssh_cmd chown root:root "${unit}"
    $ssh_cmd chmod 644 "${unit}"
done

$ssh_cmd "if [ -d /run/systemd/system ]; then systemctl daemon-reload; fi"
