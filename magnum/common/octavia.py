# Copyright 2018 Catalyst Cloud Ltd.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
import re
import time

import heatclient.exc as heat_exc
from osc_lib import exceptions as osc_exc
from oslo_config import cfg
from oslo_log import log as logging

from magnum.common import clients
from magnum.common import context as magnum_context
from magnum.common import exception
from magnum.common import neutron

LOG = logging.getLogger(__name__)
CONF = cfg.CONF


def wait_for_lb_deleted(octavia_client, deleted_lbs, max_error_retries=3):
    """Wait for the loadbalancers to be deleted.

    Load balancer deletion API in Octavia is asynchronous so that the called
    needs to wait if it wants to guarantee the load balancer to be deleted.
    The timeout is necessary to avoid waiting infinitely.

    If an LB reverts to ERROR after a delete attempt (e.g. dead amphora),
    re-issue the delete up to max_error_retries times before giving up
    on that LB.
    """
    timeout = CONF.cluster.pre_delete_lb_timeout
    start_time = time.time()
    error_counts = {}

    while True:
        lbs = octavia_client.load_balancer_list().get("loadbalancers", [])
        lb_map = {lb["id"]: lb for lb in lbs}

        still_pending = set()
        for lb_id in deleted_lbs:
            if lb_id not in lb_map:
                continue
            lb = lb_map[lb_id]
            status = lb["provisioning_status"]
            if status == "DELETED":
                continue
            if status == "ERROR":
                error_counts[lb_id] = error_counts.get(lb_id, 0) + 1
                if error_counts[lb_id] > max_error_retries:
                    LOG.error("Load balancer %s stuck in ERROR after %d "
                              "delete retries, giving up",
                              lb_id, max_error_retries)
                    continue
                LOG.warning("Load balancer %s reverted to ERROR after "
                            "delete (attempt %d/%d), retrying",
                            lb_id, error_counts[lb_id], max_error_retries)
                try:
                    octavia_client.load_balancer_delete(lb_id, cascade=True)
                except Exception as e:
                    LOG.warning("Retry delete for LB %s failed: %s",
                                lb_id, e)
            still_pending.add(lb_id)

        if not still_pending:
            break

        if (time.time() - start_time) > timeout:
            raise Exception("Timeout waiting for the load balancers "
                            "%s to be deleted." % still_pending)

        time.sleep(1)


def _wait_for_lb_ready(octavia_client, lb_id, timeout=60):
    """Wait for a load balancer to leave transitional (PENDING_*) state."""
    start_time = time.time()
    while True:
        try:
            lb = octavia_client.load_balancer_show(lb_id)
        except osc_exc.NotFound:
            return None
        status = lb["provisioning_status"]
        if not status.startswith("PENDING_"):
            return lb
        if (time.time() - start_time) > timeout:
            LOG.warning("Timed out waiting for load balancer %s to leave "
                        "%s state", lb_id, status)
            return lb
        time.sleep(2)


def _delete_loadbalancers(context, lbs, cluster, octavia_client,
                          remove_fip=False, cascade=True):
    candidates = set()

    for lb in lbs:
        status = lb["provisioning_status"]
        if status in ["PENDING_DELETE", "DELETED"]:
            if status == "PENDING_DELETE":
                candidates.add(lb["id"])
            continue

        # If the LB is in a transitional state, wait for it to settle
        # before attempting deletion.
        if status.startswith("PENDING_"):
            LOG.info("Load balancer %s for cluster %s is in %s state, "
                     "waiting for it to settle before deletion",
                     lb["id"], cluster.uuid, status)
            lb = _wait_for_lb_ready(octavia_client, lb["id"])
            if lb is None:
                # LB disappeared while waiting
                continue

        LOG.info("Deleting load balancer %s for cluster %s",
                 lb["id"], cluster.uuid)
        octavia_client.load_balancer_delete(lb["id"], cascade=cascade)
        candidates.add(lb["id"])

        if remove_fip:
            neutron.delete_floatingip(context, lb["vip_port_id"], cluster)

    return candidates


def delete_loadbalancers(context, cluster):
    """Delete loadbalancers for the cluster.

    The following load balancers are deleted:
    - The load balancers created for Kubernetes services and ingresses in
      the Kubernetes cluster.
    - The load balancers created for Kubernetes API and etcd for HA cluster.
    """
    pattern = (r'Kubernetes .+ from cluster %s' % cluster.uuid)
    lb_resource_type = "Magnum::Optional::Neutron::LBaaS::LoadBalancer"

    adm_ctx = magnum_context.get_admin_context()
    adm_clients = clients.OpenStackClients(adm_ctx)
    user_clients = clients.OpenStackClients(context)
    candidates = set()

    try:
        octavia_client_adm = adm_clients.octavia()
        heat_client = user_clients.heat()
        octavia_client = user_clients.octavia()

        # Get load balancers created for service/ingress
        lbs = octavia_client.load_balancer_list().get("loadbalancers", [])
        lbs = [lb for lb in lbs if re.match(pattern, lb["description"])]
        deleted = _delete_loadbalancers(context, lbs, cluster,
                                        octavia_client_adm, remove_fip=True)
        candidates.update(deleted)

        # NOTE (brtknr): If stack has been deleted, cluster fails to delete
        # because stack_id resolves to None. Return if that is the case.
        if not cluster.stack_id:
            return

        # Get load balancers created for Kubernetes api/etcd
        lbs = []
        try:
            lb_resources = heat_client.resources.list(
                cluster.stack_id, nested_depth=2,
                filters={"type": lb_resource_type})
        except heat_exc.HTTPNotFound:
            # NOTE(mnaser): It's possible that the stack has been deleted
            #               but Magnum still has a `stack_id` pointing.
            return
        for lb_res in lb_resources:
            lb_id = lb_res.physical_resource_id
            if not lb_id:
                continue
            try:
                lb = octavia_client.load_balancer_show(lb_id)
                lbs.append(lb)
            except osc_exc.NotFound:
                continue
        deleted = _delete_loadbalancers(context, lbs, cluster,
                                        octavia_client_adm, remove_fip=False)
        candidates.update(deleted)

        if not candidates:
            return

        wait_for_lb_deleted(octavia_client, candidates)
    except Exception as e:
        raise exception.PreDeletionFailed(cluster_uuid=cluster.uuid,
                                          msg=str(e))
