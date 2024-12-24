#!/bin/sh

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

# Set protocol and cert directory
cert_dir="/etc/etcd/certs"
protocol="https"

if [ "$TLS_DISABLED" = "True" ]; then
    protocol="http"
fi

# Get local IP
if [ -z "$KUBE_NODE_IP" ]; then
    # FIXME(yuanying): Set KUBE_NODE_IP correctly
    KUBE_NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
fi

myip="${KUBE_NODE_IP}"

# Add volume preparation section
if [ -n "$ETCD_VOLUME_SIZE" ] && [ "$ETCD_VOLUME_SIZE" -gt 0 ]; then
    attempts=60
    while [ ${attempts} -gt 0 ]; do
        device_name=$($ssh_cmd ls /dev/disk/by-id | grep ${ETCD_VOLUME:0:20}$)
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

# Add service creation section
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
    $ssh_cmd atomic install \\
    --system-package no \\
    --system \\
    --storage ostree \\
    --name=etcd ${_prefix}etcd:${ETCD_TAG}
fi

# Function to run etcdctl inside a container
run_etcdctl() {
    local endpoints="$1"
    shift
    if [ "$TLS_DISABLED" = "False" ]; then
        podman run --rm --network host \\
            --volume /etc/etcd:/etc/etcd:ro,z \\
            ${CONTAINER_INFRA_PREFIX:-"quay.io/coreos/"}etcd:${ETCD_TAG} \\
            etcdctl --endpoints="$endpoints" \\
            --cacert="$cert_dir/ca.crt" \\
            --cert="$cert_dir/server.crt" \\
            --key="$cert_dir/server.key" \\
            "$@"
    else
        podman run --rm --network host \\
            ${CONTAINER_INFRA_PREFIX:-"quay.io/coreos/"}etcd:${ETCD_TAG} \\
            etcdctl --endpoints="$endpoints" "$@"
    fi
}

# Function to check if a node is part of the cluster
is_member() {
    local endpoints="$1"
    local node_name="$2"
    local node_ip="$3"
    
    member_list=$(run_etcdctl "$endpoints" member list) || return 1
    echo "$member_list" | grep -q -E "$node_name|$node_ip" || return 1
    return 0
}

# Function to get endpoints from load balancer VIP
get_known_endpoints() {
    local endpoints=()
    local lb_endpoint="$protocol://$ETCD_LB_VIP:2379"
    
    # Try to get member list from load balancer
    local member_list=$(run_etcdctl "$lb_endpoint" member list 2>/dev/null) || return
    
    # Extract endpoints from member list
    while IFS=',' read -r id state name peerurl rest; do
        # Skip empty lines
        [ -z "$id" ] && continue
        
        # Convert peer URL to client URL (2380 to 2379)
        client_url=$(echo "$peerurl" | tr -d ' ' | cut -d'=' -f2 | sed 's/:2380/:2379/')
        
        if [ -n "$client_url" ]; then
            endpoints+=("$client_url")
        fi
    done <<< "$member_list"
    
    echo "${endpoints[@]}"
}

# Function to check if cluster exists and get endpoints
check_cluster() {
    # Get endpoints from discovery URL
    local known_endpoints=($(get_known_endpoints))
    
    echo "Found endpoints from discovery: ${known_endpoints[@]}" >&2
    
    for endpoint in "${known_endpoints[@]}"; do
        if [ "$endpoint" != "$protocol://$myip:2379" ]; then  # Skip our own IP
            if run_etcdctl "$endpoint" endpoint health >/dev/null 2>&1; then
                echo "$endpoint"
                return 0
            fi
        fi
    done
    
    # If no healthy endpoint found, return empty but don't fail
    echo ""
    return 0
}

# Function to get properly formatted member list
get_member_list() {
    local endpoints="$1"
    local my_name="$2"
    local my_ip="$3"
    local member_list=$(run_etcdctl "$endpoints" member list)
    local formatted_list=""
    
    echo "Current member list:" >&2
    echo "$member_list" >&2
    
    while IFS=',' read -r id state name peerurl rest; do
        # Skip empty lines
        [ -z "$id" ] && continue
        
        # Clean up the values
        name=$(echo "$name" | tr -d ' ')
        peerurl=$(echo "$peerurl" | tr -d ' ' | cut -d'=' -f2)
        
        # Skip entries with empty names or URLs
        [ -z "$name" ] || [ -z "$peerurl" ] && continue
        
        # For our IP, use our name
        if echo "$peerurl" | grep -q "$my_ip"; then
            name="$my_name"
        fi
        
        if [ -z "$formatted_list" ]; then
            formatted_list="$name=$peerurl"
        else
            formatted_list="$formatted_list,$name=$peerurl"
        fi
    done <<< "$member_list"
    
    echo "Formatted member list: $formatted_list" >&2
    echo "$formatted_list"
}

# Function to get cluster members from discovery URL
get_discovery_members() {
    local discovery_response=$(curl -s "$ETCD_DISCOVERY_URL")
    echo "Discovery URL response: $discovery_response" >&2
    
    # Extract existing nodes from discovery
    local nodes=$(echo "$discovery_response" | grep -o '"nodes":\[[^]]*\]' | grep -o 'value":"[^"]*' | cut -d'"' -f3)
    echo "Extracted nodes: $nodes" >&2
    
    local formatted_list=""
    for node in $nodes; do
        local name=$(echo "$node" | cut -d'=' -f1)
        local url=$(echo "$node" | cut -d'=' -f2)
        if [ -n "$name" ] && [ -n "$url" ]; then
            if [ -z "$formatted_list" ]; then
                formatted_list="$name=$url"
            else
                formatted_list="$formatted_list,$name=$url"
            fi
        fi
    done
    echo "$formatted_list"
}

# Function to clean up etcd data and stop service
cleanup_etcd() {
    echo "Cleaning up etcd data..."
    
    # Stop etcd service
    $ssh_cmd systemctl stop etcd
    
    # Remove existing container if any
    $ssh_cmd podman rm -f etcd || true
    
    # Remove all etcd data
    $ssh_cmd rm -rf /var/lib/etcd/default.etcd/*
    
    # Wait for cleanup to complete
    sleep 5
    
    echo "Etcd cleanup completed"
}

# Main logic
endpoint=$(check_cluster) || true
if [ -n "$endpoint" ]; then
    echo "Found existing cluster at $endpoint"
    
    # Clean up before joining
    cleanup_etcd
    
    # Remove any stale member entries
    member_id=$(run_etcdctl "$endpoint" member list | grep -E "$INSTANCE_NAME|$myip" | cut -d',' -f1) || true
    if [ -n "$member_id" ]; then
        echo "Removing stale member with ID $member_id"
        for i in {1..3}; do
            if run_etcdctl "$endpoint" member remove "$member_id"; then
                # Wait for removal to propagate
                sleep 5
                if ! run_etcdctl "$endpoint" member list | grep -q "$member_id"; then
                    break
                fi
            fi
            if [ $i -eq 3 ]; then
                echo "Warning: Failed to remove stale member after 3 attempts, proceeding with new cluster setup"
                endpoint=""
                break
            fi
        done
    fi
    
    if [ -n "$endpoint" ]; then
        # Add the new member
        echo "Adding node $INSTANCE_NAME to the etcd cluster"
        peer_url="$protocol://$myip:2380"
        add_output=$(run_etcdctl "$endpoint" member add "$INSTANCE_NAME" --peer-urls="$peer_url") || {
            echo "Warning: Failed to add member to cluster, proceeding with new cluster setup"
            endpoint=""
        }
        
        if [ -n "$endpoint" ]; then
            # Extract initial cluster from add output
            initial_cluster=$(echo "$add_output" | grep '^ETCD_INITIAL_CLUSTER=' | cut -d'=' -f2- | tr -d '"')
            if [ -z "$initial_cluster" ]; then
                echo "Warning: Failed to get initial cluster configuration, proceeding with new cluster setup"
                endpoint=""
            fi
        fi
    fi
fi

if [ -z "$endpoint" ]; then
    echo "No existing cluster found, creating new cluster using discovery URL"
    if [ -z "$ETCD_DISCOVERY_URL" ]; then
        echo "Error: ETCD_DISCOVERY_URL is not set"
        exit 1
    fi

    # Verify discovery URL is accessible
    if ! curl -sf "$ETCD_DISCOVERY_URL" >/dev/null; then
        echo "Error: Cannot access discovery URL: $ETCD_DISCOVERY_URL"
        exit 1
    fi

    cat > /etc/etcd/etcd.conf.yaml <<EOF
name: "$INSTANCE_NAME"
data-dir: "/var/lib/etcd/default.etcd"
listen-metrics-urls: "http://$myip:2378"
listen-client-urls: "$protocol://$myip:2379,http://127.0.0.1:2379"
listen-peer-urls: "$protocol://$myip:2380"
advertise-client-urls: "$protocol://$myip:2379"
initial-advertise-peer-urls: "$protocol://$myip:2380"
discovery: "$ETCD_DISCOVERY_URL"
heartbeat-interval: 1000
election-timeout: 15000
EOF
else
    # Create configuration for joining existing cluster
    cat > /etc/etcd/etcd.conf.yaml <<EOF
name: "$INSTANCE_NAME"
data-dir: "/var/lib/etcd/default.etcd"
listen-metrics-urls: "http://$myip:2378"
listen-client-urls: "$protocol://$myip:2379,http://127.0.0.1:2379"
listen-peer-urls: "$protocol://$myip:2380"
advertise-client-urls: "$protocol://$myip:2379"
initial-advertise-peer-urls: "$protocol://$myip:2380"
initial-cluster: "$initial_cluster"
initial-cluster-state: "existing"
heartbeat-interval: 1000
election-timeout: 15000
EOF
fi

# Add TLS configuration
if [ "$TLS_DISABLED" = "False" ]; then
    cat >> /etc/etcd/etcd.conf.yaml <<EOF
client-transport-security:
  cert-file: "$cert_dir/server.crt"
  key-file: "$cert_dir/server.key"
  client-cert-auth: true
  trusted-ca-file: "$cert_dir/ca.crt"
peer-transport-security:
  cert-file: "$cert_dir/server.crt"
  key-file: "$cert_dir/server.key"
  client-cert-auth: true
  trusted-ca-file: "$cert_dir/ca.crt"
EOF
fi

# Create backwards compatible conf file
cat > /etc/etcd/etcd.conf <<EOF
ETCD_NAME="$INSTANCE_NAME"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_CLIENT_URLS="$protocol://$myip:2379,http://127.0.0.1:2379"
ETCD_LISTEN_PEER_URLS="$protocol://$myip:2380"
ETCD_ADVERTISE_CLIENT_URLS="$protocol://$myip:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="$protocol://$myip:2380"
EOF

# Add discovery or initial cluster based on state
if [ -n "$endpoint" ]; then
    cat >> /etc/etcd/etcd.conf <<EOF
ETCD_INITIAL_CLUSTER="$initial_cluster"
ETCD_INITIAL_CLUSTER_STATE="existing"
EOF
else
    cat >> /etc/etcd/etcd.conf <<EOF
ETCD_DISCOVERY="$ETCD_DISCOVERY_URL"
EOF
fi

# Add TLS configuration if enabled
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
    cat >> /etc/etcd/etcd.conf.yaml <<EOF
# HTTP proxy to use for traffic to discovery service.
discovery-proxy: $HTTP_PROXY

EOF
fi

if [ -n "$HTTP_PROXY" ]; then
    echo "ETCD_DISCOVERY_PROXY=$HTTP_PROXY" >> /etc/etcd/etcd.conf
fi

$ssh_cmd systemctl daemon-reload
$ssh_cmd systemctl restart etcd