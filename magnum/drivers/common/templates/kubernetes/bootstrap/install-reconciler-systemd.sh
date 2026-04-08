#!/bin/bash

set -eu

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

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

# Retry up to 3 times with 30s delay on failure (e.g. transient network
# issues during binary download or Pulumi provider install).
Restart=on-failure
RestartSec=30
StartLimitIntervalSec=300
StartLimitBurst=3

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

# Retry up to 3 times with 60s delay on failure.
Restart=on-failure
RestartSec=60
StartLimitIntervalSec=600
StartLimitBurst=3

# Limit CPU impact on cluster workloads during periodic drift checks.
Nice=15
CPUWeight=20
CPUQuota=50%
EOF

cat <<EOF | $ssh_cmd "cat > /etc/systemd/system/magnum-reconcile.timer.tmp"
[Unit]
Description=Run Magnum Reconcile Periodically

[Timer]
OnActiveSec=5min
OnCalendar=*-*-* 00:00:00
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
