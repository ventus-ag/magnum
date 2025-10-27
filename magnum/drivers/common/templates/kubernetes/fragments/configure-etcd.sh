. /etc/sysconfig/heat-params

set -x

ssh_cmd="ssh -F /srv/magnum/.ssh/config root@localhost"

if [ ! -z "$HTTP_PROXY" ]; then
    export HTTP_PROXY
fi

if [ ! -z "$HTTPS_PROXY" ]; then
    export HTTPS_PROXY
fi

if [ ! -z "$NO_PROXY" ]; then
    export NO_PROXY
fi

if [ -n "$ETCD_VOLUME_SIZE" ] && [ "$ETCD_VOLUME_SIZE" -gt 0 ]; then

    attempts=60
    while [ ${attempts} -gt 0 ]; do
        device_name=$($ssh_cmd ls /dev/disk/by-id | grep ${ETCD_VOLUME:0:20} | head -n1)
        if [ -n "${device_name}" ]; then
            break
        fi
        echo "waiting for disk device"
        sleep 0.5
        $ssh_cmd udevadm trigger
        let attempts--
    done

    if [ -z "${device_name}" ]; then
        echo "ERROR: disk device does not exist" >&2
        exit 1
    fi

    device_path=/dev/disk/by-id/${device_name}
    fstype=$($ssh_cmd blkid -s TYPE -o value ${device_path} || echo "")
    if [ "${fstype}" != "xfs" ]; then
        $ssh_cmd mkfs.xfs -f ${device_path}
    fi
    $ssh_cmd mkdir -p /var/lib/etcd
    echo "${device_path} /var/lib/etcd xfs defaults 0 0" >> /etc/fstab
    $ssh_cmd mount -a
    $ssh_cmd chown -R etcd.etcd /var/lib/etcd
    $ssh_cmd chmod 755 /var/lib/etcd

fi

if [ "$(echo $USE_PODMAN | tr '[:upper:]' '[:lower:]')" == "true" ]; then
    cat > /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=Etcd server
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/sysconfig/heat-params
ExecStartPre=mkdir -p /var/lib/etcd
ExecStartPre=-/bin/podman rm etcd
ExecStart=/bin/podman run \\
    --name etcd \\
    --volume /etc/pki/ca-trust/extracted/pem:/etc/ssl/certs:ro,z \\
    --volume /etc/etcd:/etc/etcd:ro,z \\
    --volume /var/lib/etcd:/var/lib/etcd:rshared,z \\
    --net=host \\
    ${CONTAINER_INFRA_PREFIX:-"quay.io/coreos/"}etcd:${ETCD_TAG} \\
    /usr/local/bin/etcd \\
    --config-file /etc/etcd/etcd.conf.yaml
ExecStop=/bin/podman stop etcd
TimeoutStartSec=10min
IOSchedulingClass=best-effort
IOSchedulingPriority=0
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
else
    _prefix=${CONTAINER_INFRA_PREFIX:-"docker.io/openstackmagnum/"}
    $ssh_cmd atomic install \
    --system-package no \
    --system \
    --storage ostree \
    --name=etcd ${_prefix}etcd:${ETCD_TAG}
fi


if [ -z "$KUBE_NODE_IP" ]; then
    # FIXME(yuanying): Set KUBE_NODE_IP correctly
    KUBE_NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
fi

myip="${KUBE_NODE_IP}"
cert_dir="/etc/etcd/certs"
protocol="https"

if [ "$TLS_DISABLED" = "True" ]; then
    protocol="http"
fi

# -------------------------------------------------------
# etcdctl installation
# -------------------------------------------------------
etcdctl_dir="/usr/local/bin"
etcd_download_path="/srv/magnum/etcd"
$ssh_cmd mkdir -p ${etcd_download_path}
ETCD_VERSION=${ETCD_TAG#v}
etcd_tgz="${etcd_download_path}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
if [ ! -f "${etcd_tgz}" ] || ! $ssh_cmd etcdctl version 2>/dev/null | grep -q "etcdctl version: ${ETCD_VERSION}"; then
    $ssh_cmd curl --retry 5 --retry-delay 10 -L \
        https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz \
        -o "${etcd_tgz}.tmp"
    $ssh_cmd mv "${etcd_tgz}.tmp" "${etcd_tgz}"
    $ssh_cmd mkdir -p ${etcd_download_path}/tmp
    $ssh_cmd tar -C ${etcd_download_path}/tmp -xzf ${etcd_tgz}
    $ssh_cmd cp ${etcd_download_path}/tmp/etcd-v${ETCD_VERSION}-linux-amd64/etcdctl ${etcdctl_dir}/
    $ssh_cmd chmod +x ${etcdctl_dir}/etcdctl
    $ssh_cmd rm -rf ${etcd_download_path}/tmp
fi

# -------------------------------------------------------
# Helper functions for etcd rejoin logic
# -------------------------------------------------------

run_etcdctl() {
    local endpoints="$1"
    shift
    local max_attempts=3
    local attempt=1
    local delay=3
    local timeout=5
    local etcdctl_opts=(
        "--endpoints=$endpoints"
        "--command-timeout=${timeout}s"
    )
    if [ "$TLS_DISABLED" != "True" ]; then
        etcdctl_opts+=(
            --cacert="$cert_dir/ca.crt"
            --cert="$cert_dir/server.crt"
            --key="$cert_dir/server.key"
        )
    fi
    while [ ${attempt} -le ${max_attempts} ]; do
        echo "Attempt $attempt/$max_attempts: etcdctl $*" >&2
        if output=$($ssh_cmd ETCDCTL_API=3 ${etcdctl_dir}/etcdctl "${etcdctl_opts[@]}" "$@" 2>&1); then
            echo "$output"
            return 0
        fi
        echo "$output" >&2
        sleep $delay
        let attempt++
    done
    return 1
}

# Checks if our node is already a member using endpoint
is_member() {
    local endpoints="$1"
    local node_name="$2"
    local node_ip="$3"
    member_list=$(run_etcdctl "$endpoints" member list) || return 1
    echo "$member_list" | grep -q -E "$node_name|$node_ip" || return 1
    return 0
}

# Build configuration string based on mode
build_config() {
    local mode="$1"
    local extra="${2:-}"
    if [ "$mode" = "new" ]; then
        cat << ETCDEOF
name: "$INSTANCE_NAME"
data-dir: "/var/lib/etcd/default.etcd"
listen-metrics-urls: "http://$myip:2378"
listen-client-urls: "$protocol://$myip:2379,http://127.0.0.1:2379"
listen-peer-urls: "$protocol://$myip:2380"
advertise-client-urls: "$protocol://$myip:2379"
initial-advertise-peer-urls: "$protocol://$myip:2380"
discovery: "$ETCD_DISCOVERY_URL"
heartbeat-interval: 500
election-timeout: 5000
ETCDEOF
    elif [ "$mode" = "existing" ]; then
        cat << ETCDEOF
name: "$INSTANCE_NAME"
data-dir: "/var/lib/etcd/default.etcd"
listen-metrics-urls: "http://$myip:2378"
listen-client-urls: "$protocol://$myip:2379,http://127.0.0.1:2379"
listen-peer-urls: "$protocol://$myip:2380"
advertise-client-urls: "$protocol://$myip:2379"
initial-advertise-peer-urls: "$protocol://$myip:2380"
initial-cluster: "$extra"
initial-cluster-state: "existing"
heartbeat-interval: 500
election-timeout: 5000
ETCDEOF
    fi
}

# Remove our node from cluster and add it back
rejoin_cluster() {
    echo "Rejoining cluster via LB endpoint $lb_endpoint" >&2
    member_id=$(run_etcdctl "$lb_endpoint" member list | grep -E "$INSTANCE_NAME|$myip" | cut -d',' -f1)
    [ -n "$member_id" ] && run_etcdctl "$lb_endpoint" member remove "$member_id" || true
    if add_output=$(run_etcdctl "$lb_endpoint" member add "$INSTANCE_NAME" --peer-urls="$protocol://$myip:2380"); then
        initial_cluster=$(echo "$add_output" | grep '^ETCD_INITIAL_CLUSTER=' | cut -d'=' -f2- | tr -d '"')
        config=$(build_config existing "$initial_cluster")
        write_and_start_etcd "$config"
        return 0
    else
        echo "Failed to rejoin cluster via LB" >&2
        return 1
    fi
}

# Clean up etcd data and stop service
cleanup_etcd() {
    echo "Cleaning up etcd data..." >&2
    $ssh_cmd systemctl stop etcd || true
    $ssh_cmd podman rm -f etcd || true
    sleep 5
    echo "Etcd cleanup completed" >&2
}

# Check if the discovery URL is valid
check_discovery_url() {
    local url="$1"
    if [ -n "$url" ]; then
        local data
        data=$(curl -sf "$url") || true
        if [ -n "$data" ] && ! echo "$data" | grep -q "unable to GET token"; then
            if echo "$data" | grep -q '"nodes":\['; then
                echo "Discovery URL contains existing cluster data" >&2
                return 0
            elif echo "$data" | jq -e '.node.nodes' >/dev/null 2>&1; then
                echo "Discovery URL contains existing cluster data" >&2
                return 0
            elif echo "$data" | grep -q '"dir":true'; then
                echo "Discovery URL is valid but empty, can be used for new cluster" >&2
                return 0
            fi
        fi
    fi
    echo "Discovery URL is not valid or contains no cluster data" >&2
    return 1
}

# Write etcd configuration and start the service
write_and_start_etcd() {
    local config_content="$1"
    $ssh_cmd mkdir -p /etc/etcd
    echo "$config_content" > /etc/etcd/etcd.conf.yaml
    if [ ! -f /etc/etcd/etcd.conf.yaml ]; then
        echo "Failed to write etcd config file" >&2
        return 1
    else
        echo "Starting etcd service..." >&2
        $ssh_cmd systemctl daemon-reload
        $ssh_cmd systemctl restart etcd
        return 0
    fi
}

# -------------------------------------------------------
# Cluster Join/Creation Logic with Rejoin Support
# -------------------------------------------------------

local_endpoint="$protocol://$myip:2379"
lb_endpoint="$protocol://$ETCD_LB_VIP:2379"

# Check discovery URL validity
discovery_ok=0
if check_discovery_url "$ETCD_DISCOVERY_URL"; then
    discovery_ok=1
fi

# Check LB VIP response
lb_ok=0
if run_etcdctl "$lb_endpoint" endpoint health >/dev/null 2>&1; then
    lb_ok=1
fi

# Check local endpoint health
local_ok=0
if run_etcdctl "$local_endpoint" endpoint health >/dev/null 2>&1; then
    local_ok=1
fi

echo "Discovery OK: $discovery_ok, LB OK: $lb_ok, Local OK: $local_ok" >&2

# Decision tree for cluster join/creation/rejoin
if [ $discovery_ok -eq 1 ]; then
    if [ $lb_ok -eq 1 ]; then
        if is_member "$lb_endpoint" "$INSTANCE_NAME" "$myip"; then
            echo "Discovery valid and LB shows our node as a member." >&2
            if [ $local_ok -eq 0 ]; then
                echo "Local endpoint is unhealthy. Triggering rejoin." >&2
                cleanup_etcd
                rejoin_cluster || exit 1
            else
                echo "Local endpoint is healthy. Skipping join/creation logic." >&2
            fi
        else
            echo "Discovery valid but LB does not list our node. Creating new cluster using discovery URL." >&2
            cleanup_etcd
            config=$(build_config new)
            write_and_start_etcd "$config"
        fi
    else
        echo "LB not available but discovery URL is valid. Creating new cluster using discovery URL." >&2
        cleanup_etcd
        config=$(build_config new)
        write_and_start_etcd "$config"
    fi
elif [ $discovery_ok -eq 0 ]; then
    if [ $lb_ok -eq 1 ]; then
        if is_member "$lb_endpoint" "$INSTANCE_NAME" "$myip"; then
            echo "Discovery invalid but LB shows our node as a member." >&2
            if [ $local_ok -eq 0 ]; then
                echo "Local endpoint is unhealthy. Triggering rejoin." >&2
                cleanup_etcd
                rejoin_cluster || exit 1
            else
                echo "Local endpoint is healthy. Skipping join/creation logic." >&2
            fi
        else
            echo "Error: Discovery URL is invalid and LB does not list our node. Cannot proceed." >&2
            exit 1
        fi
    else
        echo "Error: Neither a valid discovery URL nor a healthy LB endpoint is available." >&2
        exit 1
    fi
fi

# If we got here and etcd config doesn't exist or is incomplete, create static config as fallback
if [ ! -f /etc/etcd/etcd.conf.yaml ] || ! grep -q "name:" /etc/etcd/etcd.conf.yaml; then
    echo "Creating fallback etcd configuration..." >&2
    cat > /etc/etcd/etcd.conf.yaml <<EOF
# This is the configuration file for the etcd server.

# Human-readable name for this member.
name: "${INSTANCE_NAME}"

# Path to the data directory.
data-dir: /var/lib/etcd/default.etcd

# List of comma separated URLs to listen on for peer traffic.
listen-peer-urls: "$protocol://$myip:2380"

# Only for /metrics url
listen-metrics-urls: "http://$myip:2378"

# List of comma separated URLs to listen on for client traffic.
listen-client-urls: "$protocol://$myip:2379,http://127.0.0.1:2379"

# List of this member's peer URLs to advertise to the rest of the cluster.
# The URLs needed to be a comma-separated list.
initial-advertise-peer-urls: "$protocol://$myip:2380"

# List of this member's client URLs to advertise to the public.
# The URLs needed to be a comma-separated list.
advertise-client-urls: "$protocol://$myip:2379,http://127.0.0.1:2379"

# Discovery URL used to bootstrap the cluster.
discovery: "$ETCD_DISCOVERY_URL"

# Time (in milliseconds) of a heartbeat interval. default: 100
heartbeat-interval: 1000

# Time (in milliseconds) for an election to timeout. default: 1000
election-timeout: 15000

EOF
fi

# Append TLS and proxy configuration if needed
if [ -n "$HTTP_PROXY" ]; then
    cat >> /etc/etcd/etcd.conf.yaml <<EOF
# HTTP proxy to use for traffic to discovery service.
discovery-proxy: $HTTP_PROXY

EOF
fi

if [ "$TLS_DISABLED" = "False" ]; then
    cat >> /etc/etcd/etcd.conf.yaml <<EOF
client-transport-security:
  # Path to the client server TLS cert file.
  cert-file: $cert_dir/server.crt

  # Path to the client server TLS key file.
  key-file: $cert_dir/server.key

  # Enable client cert authentication.
  client-cert-auth: true

  # Path to the client server TLS trusted CA cert file.
  trusted-ca-file: $cert_dir/ca.crt

peer-transport-security:
  # Path to the peer server TLS cert file.
  cert-file: $cert_dir/server.crt

  # Path to the peer server TLS key file.
  key-file: $cert_dir/server.key

  # Enable peer client cert authentication.
  client-cert-auth: true

  # Path to the peer server TLS trusted CA cert file.
  trusted-ca-file: $cert_dir/ca.crt
EOF
fi
# backwards compatible conf file
cat > /etc/etcd/etcd.conf <<EOF
ETCD_NAME="$INSTANCE_NAME"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_CLIENT_URLS="$protocol://$myip:2379,http://127.0.0.1:2379"
ETCD_LISTEN_PEER_URLS="$protocol://$myip:2380"
ETCD_ADVERTISE_CLIENT_URLS="$protocol://$myip:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="$protocol://$myip:2380"
ETCD_DISCOVERY="$ETCD_DISCOVERY_URL"
EOF

if [ "$TLS_DISABLED" = "False" ]; then

cat >> /etc/etcd/etcd.conf <<EOF
ETCD_CA_FILE=$cert_dir/ca.crt
ETCD_TRUSTED_CA_FILE=$cert_dir/ca.crt
ETCD_CERT_FILE=$cert_dir/server.crt
ETCD_KEY_FILE=$cert_dir/server.key
ETCD_CLIENT_CERT_AUTH=true
ETCD_PEER_CA_FILE=$cert_dir/ca.crt
ETCD_PEER_TRUSTED_CA_FILE=$cert_dir/ca.crt
ETCD_PEER_CERT_FILE=$cert_dir/server.crt
ETCD_PEER_KEY_FILE=$cert_dir/server.key
ETCD_PEER_CLIENT_CERT_AUTH=true
EOF

fi

if [ -n "$HTTP_PROXY" ]; then
    echo "ETCD_DISCOVERY_PROXY=$HTTP_PROXY" >> /etc/etcd/etcd.conf
fi

$ssh_cmd systemctl daemon-reload
$ssh_cmd systemctl restart etcd