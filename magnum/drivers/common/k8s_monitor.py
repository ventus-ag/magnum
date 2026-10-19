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

import ast
import json

from heatclient import exc as heat_exc
from kubernetes.client import rest as k8s_rest
from oslo_log import log as logging
from oslo_utils import strutils
from oslo_utils import timeutils
import urllib3

from magnum.common import clients
from magnum.common import utils
from magnum.conductor import k8s_api as k8s
from magnum.conductor import monitors
import magnum.conf
from magnum import objects
from magnum.objects import fields as m_fields

CONF = magnum.conf.CONF
LOG = logging.getLogger(__name__)

# Octavia operating statuses that say nothing is wrong with the API members.
_LB_OK_STATUSES = ('ONLINE', 'NO_MONITOR')

# Immutable per cluster/stack, so resolved once per conductor process.
_api_lb_ids = {}
_stack_names = {}


class ClusterUnreachable(Exception):
    """The cluster's Kubernetes API gave no response at all."""


def _health_request_timeout():
    """(connect, read) timeout for cluster health requests, or None."""
    seconds = CONF.kubernetes.health_request_timeout
    if not seconds or seconds <= 0:
        return None
    return (seconds, seconds)


def _is_no_response(exc):
    if isinstance(exc, k8s_rest.ApiException):
        # The client reports TLS failures as status 0.
        return not exc.status
    return isinstance(exc, (urllib3.exceptions.HTTPError, OSError))


class K8sMonitor(monitors.MonitorBase):

    def __init__(self, context, cluster):
        super(K8sMonitor, self).__init__(context, cluster)
        self.data = {}
        self.data['nodes'] = []
        self.data['pods'] = []

    @property
    def metrics_spec(self):
        return {
            'memory_util': {
                'unit': '%',
                'func': 'compute_memory_util',
            },
            'cpu_util': {
                'unit': '%',
                'func': 'compute_cpu_util',
            },
        }

    def pull_data(self):
        k8s_api = k8s.create_k8s_api(self.context, self.cluster)
        nodes = k8s_api.list_node()
        self.data['nodes'] = self._parse_node_info(nodes)
        pods = k8s_api.list_namespaced_pod('default')
        self.data['pods'] = self._parse_pod_info(pods)

    def poll_health_status(self, skip_api=False):
        """Poll cluster health.

        :param skip_api: the API is in its unreachable backoff window, so
            report OpenStack-derived health without trying it.
        """
        if (self._is_magnum_auto_healer_running() or
                self._has_fresh_external_health_report()):
            return

        if not self._is_cluster_accessible():
            status, reason = self._unreachable_health_status(
                "The cluster %s is not accessible." % self.cluster.name)
        elif skip_api:
            status, reason = self._unreachable_health_status(
                "Kubernetes API unreachable from Magnum (backed off).")
        else:
            k8s_api = k8s.create_k8s_api(self.context, self.cluster,
                                         retries=False)
            try:
                status, reason = self._poll_health_status(k8s_api)
            except ClusterUnreachable as e:
                if not CONF.kubernetes.health_openstack_fallback:
                    raise
                LOG.info("Cluster %(cluster)s API unreachable from Magnum: "
                         "%(e)s", {'cluster': self.cluster.uuid,
                                   'e': e.__cause__})
                self.data['api_unreachable'] = True
                status, reason = self._unreachable_health_status(
                    "Kubernetes API unreachable from Magnum (%s)." % e)

        self.data['health_status'] = status
        self.data['health_status_reason'] = reason

    def _unreachable_health_status(self, api_reason):
        if not CONF.kubernetes.health_openstack_fallback:
            return m_fields.ClusterHealthStatus.UNKNOWN, {'api': api_reason}
        return self._poll_openstack_health(api_reason)

    def _poll_openstack_health(self, api_reason):
        """Health as OpenStack sees it, for an API Magnum cannot reach.

        Weaker than the Kubernetes poll: it proves the servers run and the
        API load balancer's members accept TCP, not that nodes are Ready.
        """
        reason = {'api': api_reason, 'source': 'openstack'}
        try:
            osc = clients.OpenStackClients(self.context)
            lb_status = self._api_lb_operating_status(osc)
            servers = self._cluster_servers(osc)
        except Exception as e:
            LOG.warning("Cannot derive health of cluster %(cluster)s from "
                        "OpenStack: %(e)s",
                        {'cluster': self.cluster.uuid, 'e': e})
            reason['openstack'] = 'lookup failed'
            return m_fields.ClusterHealthStatus.UNKNOWN, reason

        if not servers:
            reason['openstack'] = 'no servers found'
            return m_fields.ClusterHealthStatus.UNKNOWN, reason

        healthy = True
        if lb_status is not None:
            reason['loadbalancer'] = lb_status
            healthy = lb_status in _LB_OK_STATUSES
        for server in servers:
            reason[server.name + '.status'] = server.status
            healthy = healthy and server.status == 'ACTIVE'

        if healthy:
            return m_fields.ClusterHealthStatus.HEALTHY, reason
        return m_fields.ClusterHealthStatus.UNHEALTHY, reason

    def _api_lb_operating_status(self, osc):
        if not self.cluster.master_lb_enabled or not self.cluster.stack_id:
            return None

        lb_id = _api_lb_ids.get(self.cluster.uuid)
        if lb_id is None:
            heat = osc.heat()
            try:
                lb_stack = heat.resources.get(
                    self.cluster.stack_id, 'api_lb').physical_resource_id
                lb_id = heat.resources.get(
                    lb_stack, 'loadbalancer').physical_resource_id
            except heat_exc.HTTPNotFound:
                return None
            if not lb_id:
                return None
            _api_lb_ids[self.cluster.uuid] = lb_id

        try:
            lb = osc.octavia().load_balancer_show(lb_id)
        except Exception:
            _api_lb_ids.pop(self.cluster.uuid, None)
            raise
        return lb['operating_status']

    def _cluster_servers(self, osc):
        # Additional nodegroups live in their own stacks; their servers are
        # named after that stack, never after the cluster.
        stack_ids = {ng.stack_id for ng in
                     objects.NodeGroup.list(self.context, self.cluster.uuid)
                     if ng.stack_id}
        if self.cluster.stack_id:
            stack_ids.add(self.cluster.stack_id)
        if not stack_ids:
            return []

        names = []
        for stack_id in sorted(stack_ids):
            name = _stack_names.get(stack_id)
            if name is None:
                name = osc.heat().stacks.get(stack_id).stack_name
                _stack_names[stack_id] = name
            names.append(name)

        # Stack names are sanitised to [a-z0-9-], so need no regex escaping.
        return osc.nova().servers.list(search_opts={
            'all_tenants': True,
            'tenant_id': self.cluster.project_id,
            'name': '^(%s)-' % '|'.join(names),
        })

    def _is_magnum_auto_healer_running(self):
        auto_healing = self.cluster.labels.get("auto_healing_enabled")
        auto_healing_enabled = strutils.bool_from_string(auto_healing)
        controller = self.cluster.labels.get("auto_healing_controller")
        return (auto_healing_enabled and controller == "magnum-auto-healer")

    def _has_fresh_external_health_report(self):
        auto_healing = self.cluster.labels.get("auto_healing_enabled")
        if not strutils.bool_from_string(auto_healing):
            return False

        controller = self.cluster.labels.get("auto_healing_controller")
        if controller and controller != "magnum-auto-healer":
            return False

        reason = self.cluster.health_status_reason or {}
        reported_at = self.cluster.updated_at
        if 'updated_at' not in reason or reported_at is None:
            return False

        max_age = max(CONF.kubernetes.health_polling_interval * 2, 60)
        age = timeutils.delta_seconds(
            reported_at, timeutils.utcnow(with_timezone=True))
        return abs(age) <= max_age

    def _is_cluster_accessible(self):
        if self.cluster.master_lb_enabled:
            lb_fip = self.cluster.labels.get("master_lb_floating_ip_enabled",
                                             self.cluster.floating_ip_enabled)
            return strutils.bool_from_string(lb_fip)
        else:
            return self.cluster.floating_ip_enabled

    def _compute_res_util(self, res):
        res_total = 0
        for node in self.data['nodes']:
            res_total += node[res]
        res_reserved = 0

        for pod in self.data['pods']:
            res_reserved += pod[res]

        if res_total == 0:
            return 0
        else:
            return res_reserved * 100 / res_total

    def compute_memory_util(self):
        return self._compute_res_util('Memory')

    def compute_cpu_util(self):
        return self._compute_res_util('Cpu')

    def _parse_pod_info(self, pods):
        """Parse pods and retrieve memory and cpu details about each pod

        :param pods: The output of k8s_api.list_namespaced_pod()
        For example:
        {
            'items': [{
                'status': {
                    'container_statuses': None,
                    'pod_ip': None,
                    'phase': 'Pending',
                    'message': None,
                    'conditions': None,
                },
                'spec': {
                    'containers': [{
                        'image': 'nginx',
                        'resources': {'requests': None,
                              'limits': "{u'cpu': u'500m',
                                          u'memory': u'1280e3'}"},
                    }],
                },
                'api_version': None,
            }],
            'kind': 'PodList',
        }

        The above output is the dict form of:
        k8sclient.client.models.v1_pod_list.
        V1PodList object

        :return: Memory size of each pod. Example:
            [{'Memory': 1280000.0, cpu: 0.5},
             {'Memory': 1280000.0, cpu: 0.5}]
        """
        pods = pods.items
        parsed_containers = []
        for pod in pods:
            containers = pod.spec.containers
            for container in containers:
                memory = 0
                cpu = 0
                resources = container.resources
                limits = resources.limits
                if limits is not None:
                    # Output of resources.limits is string
                    # for example:
                    # limits = "{cpu': '500m': 'memory': '1000Ki'}"
                    limits = ast.literal_eval(limits)
                    if limits.get('memory', ''):
                        memory = utils.get_k8s_quantity(limits['memory'])
                    if limits.get('cpu', ''):
                        cpu = utils.get_k8s_quantity(limits['cpu'])
                container_dict = {
                    'Memory': memory,
                    'Cpu': cpu,
                }
                parsed_containers.append(container_dict)
        return parsed_containers

    def _parse_node_info(self, nodes):
        """Parse nodes to retrieve memory and cpu of each node

        :param nodes: The output of k8s_api.list_namespaced_node()
        For example:
        {
            'items': [{
                'status': {
                    'phase': None,
                    'capacity': "{u'cpu': u'1',
                                  u'memory': u'2049852Ki'}",
                },
            }],
            'api_version': None,
            'kind': 'NodeList',
            'api_version': 'v1',
        }

        The above output is the dict form of:
        k8sclient.client.models.v1_node_list.
        V1NodeList object

        :return: CPU core number and Memory size of each node. Example:
            [{'cpu': 1, 'Memory': 1024.0},
             {'cpu': 1, 'Memory': 1024.0}]

        """
        nodes = nodes.items
        parsed_nodes = []
        for node in nodes:
            # Output of node.status.capacity is strong
            # for example:
            # capacity = "{'cpu': '1', 'memory': '1000Ki'}"
            capacity = node.status.capacity
            memory = utils.get_k8s_quantity(capacity['memory'])
            cpu = int(capacity['cpu'])
            parsed_nodes.append({'Memory': memory, 'Cpu': cpu})

        return parsed_nodes

    def _poll_health_status(self, k8s_api):
        """Poll health status of API and nodes for given cluster

        Design Policy:
        1.  How to calculate the overall health status?
            Any node (including API and minion nodes) is not OK, then the
            overall health status is UNHEALTHY

        2.  The data structure of health_status_reason
            As an attribute of the cluster, the health_status_reason have to
            use the field type from
            oslo.versionedobjects/blob/master/oslo_versionedobjects/fields.py

        3.  How to get the health_status and health_status_reason?
            3.1 Call /healthz to get the API health status
            3.2 Call list_node (using API /api/v1/nodes) to get the nodes
                health status

        :param k8s_api: The api client to the cluster
        :return: Tumple including status and reason. Example:
            (
                ClusterHealthStatus.HEALTHY,
                {
                    'api': 'ok',
                    'k8scluster-ydz7cfbxqqu3-node-0.Ready': False,
                    'k8scluster-ydz7cfbxqqu3-node-1.Ready': True,
                    'k8scluster-ydz7cfbxqqu3-node-2.Ready': True,
                }
            )

        """

        health_status = m_fields.ClusterHealthStatus.UNHEALTHY
        health_status_reason = {}
        api_status = None

        # Bound every request. These calls are otherwise UNBOUNDED, and a
        # cluster whose API is dead behind a live load balancer stalls in the
        # TLS handshake -- which urllib3 then retries three times. The stall
        # happens inside the conductor, so a few such clusters starve the
        # synchronous RPCs the API is waiting on and upgrades come back as
        # gateway errors. See [kubernetes] health_request_timeout.
        timeout = _health_request_timeout()

        try:
            api_status, _, _ = k8s_api.api_client.call_api(
                '/healthz', 'GET', response_type=object,
                _request_timeout=timeout)

            self._poll_version(k8s_api)

            for node in k8s_api.list_node(_request_timeout=timeout).items:
                node_key = node.metadata.name + ".Ready"
                ready = False
                for condition in node.status.conditions:
                    if condition.type == 'Ready':
                        ready = strutils.bool_from_string(condition.status)
                        break

                health_status_reason[node_key] = ready

            if (api_status == 'ok' and
                    all(n for n in health_status_reason.values())):
                health_status = m_fields.ClusterHealthStatus.HEALTHY

            health_status_reason['api'] = api_status
        except Exception as exp_api:
            if not api_status and _is_no_response(exp_api):
                raise ClusterUnreachable(
                    type(exp_api).__name__) from exp_api
            if not api_status:
                api_status = (getattr(exp_api, 'body', None) or
                              getattr(exp_api, 'message', None))
                if api_status is not None:
                    health_status_reason['api'] = api_status

        return health_status, health_status_reason

    def _poll_version(self, k8s_api):
        try:
            version_raw, _, _ = k8s_api.api_client.call_api(
                '/version', 'GET', response_type=object,
                _request_timeout=_health_request_timeout())
            if isinstance(version_raw, str):
                version_info = json.loads(version_raw)
            else:
                version_info = version_raw
            git_version = version_info.get('gitVersion')
            if git_version and git_version != self.cluster.coe_version:
                self.data['coe_version'] = git_version
        except Exception as e:
            LOG.warning(
                "Failed to get version from cluster %(cluster)s: %(e)s",
                {'e': e, 'cluster': self.cluster.uuid})
