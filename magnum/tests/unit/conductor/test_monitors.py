# Copyright 2015 Huawei Technologies Co.,LTD.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from collections import namedtuple
from unittest import mock

from heatclient import exc as heat_exc
from kubernetes.client import rest as k8s_rest
import urllib3

from magnum.common import exception
from magnum.drivers.common import k8s_monitor
from magnum import objects
from magnum.objects import fields as m_fields
from magnum.tests import base
from magnum.tests.unit.db import utils

NODE_STATUS_CONDITION = namedtuple('Condition',
                                   ['type', 'status'])


class MonitorsTestCase(base.TestCase):

    test_metrics_spec = {
        'metric1': {
            'unit': 'metric1_unit',
            'func': 'metric1_func',
        },
        'metric2': {
            'unit': 'metric2_unit',
            'func': 'metric2_func',
        },
    }

    def setUp(self):
        super(MonitorsTestCase, self).setUp()
        cluster = utils.get_test_cluster(node_addresses=['1.2.3.4'],
                                         api_address='https://5.6.7.8:2376',
                                         master_addresses=['10.0.0.6'],
                                         labels={})
        self.cluster = objects.Cluster(self.context, **cluster)
        cluster_template = (
            utils.get_test_cluster_template(master_lb_enabled=False))
        self.cluster.cluster_template = (
            objects.ClusterTemplate(self.context, **cluster_template))
        nodegroups = utils.get_nodegroups_for_cluster(
            node_addresses=['1.2.3.4'], master_addresses=['10.0.0.6'])
        self.nodegroups = [
            objects.NodeGroup(self.context, **nodegroups['master']),
            objects.NodeGroup(self.context, **nodegroups['worker'])
        ]
        self.k8s_monitor = k8s_monitor.K8sMonitor(self.context, self.cluster)
        k8s_monitor._api_lb_ids.clear()
        k8s_monitor._stack_names.clear()

    @mock.patch('magnum.conductor.k8s_api.create_k8s_api')
    def test_k8s_monitor_pull_data_success(self, mock_k8s_api):
        mock_nodes = mock.MagicMock()
        mock_node = mock.MagicMock()
        mock_node.status = mock.MagicMock()
        mock_node.status.capacity = {'memory': '2000Ki', 'cpu': '1'}
        mock_nodes.items = [mock_node]
        mock_k8s_api.return_value.list_node.return_value = (
            mock_nodes)
        mock_pods = mock.MagicMock()
        mock_pod = mock.MagicMock()
        mock_pod.spec = mock.MagicMock()
        mock_container = mock.MagicMock()
        mock_container.resources = mock.MagicMock()
        mock_container.resources.limits = "{'memory': '100Mi', 'cpu': '500m'}"
        mock_pod.spec.containers = [mock_container]
        mock_pods.items = [mock_pod]
        mock_k8s_api.return_value.list_namespaced_pod.return_value = mock_pods

        self.k8s_monitor.pull_data()
        self.assertEqual(self.k8s_monitor.data['nodes'],
                         [{'Memory': 2048000.0, 'Cpu': 1}])
        self.assertEqual(self.k8s_monitor.data['pods'],
                         [{'Memory': 104857600.0, 'Cpu': 0.5}])

    def test_k8s_monitor_get_metric_names(self):
        k8s_metric_spec = 'magnum.drivers.common.k8s_monitor.K8sMonitor.'\
                          'metrics_spec'
        with mock.patch(k8s_metric_spec,
                        new_callable=mock.PropertyMock) as mock_k8s_metric:
            mock_k8s_metric.return_value = self.test_metrics_spec
            names = self.k8s_monitor.get_metric_names()
            self.assertEqual(sorted(['metric1', 'metric2']), sorted(names))

    def test_k8s_monitor_get_metric_unit(self):
        k8s_metric_spec = 'magnum.drivers.common.k8s_monitor.K8sMonitor.'\
                          'metrics_spec'
        with mock.patch(k8s_metric_spec,
                        new_callable=mock.PropertyMock) as mock_k8s_metric:
            mock_k8s_metric.return_value = self.test_metrics_spec
            unit = self.k8s_monitor.get_metric_unit('metric1')
            self.assertEqual('metric1_unit', unit)

    def test_k8s_monitor_compute_memory_util(self):
        test_data = {
            'nodes': [
                {
                    'Memory': 20,
                },
            ],
            'pods': [
                {
                    'Memory': 10,
                },
            ],
        }
        self.k8s_monitor.data = test_data
        mem_util = self.k8s_monitor.compute_memory_util()
        self.assertEqual(50, mem_util)

        test_data = {
            'nodes': [],
            'pods': [],
        }
        self.k8s_monitor.data = test_data
        mem_util = self.k8s_monitor.compute_memory_util()
        self.assertEqual(0, mem_util)

    def test_k8s_monitor_compute_cpu_util(self):
        test_data = {
            'nodes': [
                {
                    'Cpu': 1,
                },
            ],
            'pods': [
                {
                    'Cpu': 0.5,
                },
            ],
        }
        self.k8s_monitor.data = test_data
        cpu_util = self.k8s_monitor.compute_cpu_util()
        self.assertEqual(50, cpu_util)

        test_data = {
            'nodes': [],
            'pods': [],
        }
        self.k8s_monitor.data = test_data
        cpu_util = self.k8s_monitor.compute_cpu_util()
        self.assertEqual(0, cpu_util)

    @mock.patch('magnum.conductor.k8s_api.create_k8s_api')
    def test_k8s_monitor_health_healthy(self, mock_k8s_api):
        mock_nodes = mock.MagicMock()
        mock_node = mock.MagicMock()
        mock_api_client = mock.MagicMock()
        mock_node.status = mock.MagicMock()
        mock_node.metadata.name = 'k8s-cluster-node-0'
        mock_node.status.conditions = [NODE_STATUS_CONDITION(type='Ready',
                                                             status='True')]
        mock_nodes.items = [mock_node]
        mock_k8s_api.return_value.list_node.return_value = (
            mock_nodes)
        mock_k8s_api.return_value.api_client = mock_api_client
        mock_api_client.call_api.return_value = ('ok', None, None)

        self.k8s_monitor.poll_health_status()
        self.assertEqual(self.k8s_monitor.data['health_status'],
                         m_fields.ClusterHealthStatus.HEALTHY)
        self.assertEqual(self.k8s_monitor.data['health_status_reason'],
                         {'api': 'ok', 'k8s-cluster-node-0.Ready': True})

    @mock.patch('magnum.conductor.k8s_api.create_k8s_api')
    def test_k8s_monitor_health_unhealthy_api(self, mock_k8s_api):
        mock_nodes = mock.MagicMock()
        mock_node = mock.MagicMock()
        mock_api_client = mock.MagicMock()
        mock_node.status = mock.MagicMock()
        mock_node.metadata.name = 'k8s-cluster-node-0'
        mock_node.status.conditions = [NODE_STATUS_CONDITION(type='Ready',
                                                             status='True')]
        mock_nodes.items = [mock_node]
        mock_k8s_api.return_value.list_node.return_value = (
            mock_nodes)
        mock_k8s_api.return_value.api_client = mock_api_client
        mock_api_client.call_api.side_effect = exception.MagnumException(
            message='failed')

        self.k8s_monitor.poll_health_status()
        self.assertEqual(self.k8s_monitor.data['health_status'],
                         m_fields.ClusterHealthStatus.UNHEALTHY)
        self.assertEqual(self.k8s_monitor.data['health_status_reason'],
                         {'api': 'failed'})

    @mock.patch('magnum.conductor.k8s_api.create_k8s_api')
    def test_k8s_monitor_health_unhealthy_node(self, mock_k8s_api):
        mock_nodes = mock.MagicMock()
        mock_api_client = mock.MagicMock()

        mock_node0 = mock.MagicMock()
        mock_node0.status = mock.MagicMock()
        mock_node0.metadata.name = 'k8s-cluster-node-0'
        mock_node0.status.conditions = [NODE_STATUS_CONDITION(type='Ready',
                                                              status='False')]
        mock_node1 = mock.MagicMock()
        mock_node1.status = mock.MagicMock()
        mock_node1.metadata.name = 'k8s-cluster-node-1'
        mock_node1.status.conditions = [NODE_STATUS_CONDITION(type='Ready',
                                                              status='True')]

        mock_nodes.items = [mock_node0, mock_node1]
        mock_k8s_api.return_value.list_node.return_value = (
            mock_nodes)
        mock_k8s_api.return_value.api_client = mock_api_client
        mock_api_client.call_api.return_value = ('ok', None, None)

        self.k8s_monitor.poll_health_status()
        self.assertEqual(self.k8s_monitor.data['health_status'],
                         m_fields.ClusterHealthStatus.UNHEALTHY)
        self.assertEqual(self.k8s_monitor.data['health_status_reason'],
                         {'api': 'ok', 'k8s-cluster-node-0.Ready': False,
                          'api': 'ok', 'k8s-cluster-node-1.Ready': True})

    @mock.patch('magnum.conductor.k8s_api.create_k8s_api')
    def test_k8s_monitor_health_unreachable_cluster(self, mock_k8s_api):
        mock_nodes = mock.MagicMock()
        mock_node = mock.MagicMock()
        mock_node.status = mock.MagicMock()
        mock_nodes.items = [mock_node]
        self.k8s_monitor.cluster.floating_ip_enabled = False
        self.config(health_openstack_fallback=False, group='kubernetes')

        self.k8s_monitor.poll_health_status()
        self.assertEqual(self.k8s_monitor.data['health_status'],
                         m_fields.ClusterHealthStatus.UNKNOWN)
        self.assertEqual(self.k8s_monitor.data['health_status_reason'],
                         {'api': 'The cluster cluster1 is not accessible.'})
        mock_k8s_api.assert_not_called()

    @mock.patch('magnum.conductor.k8s_api.create_k8s_api')
    def test_k8s_monitor_health_unreachable_with_master_lb(self, mock_k8s_api):
        mock_nodes = mock.MagicMock()
        mock_node = mock.MagicMock()
        mock_node.status = mock.MagicMock()
        mock_nodes.items = [mock_node]
        cluster = self.k8s_monitor.cluster
        cluster.floating_ip_enabled = True
        cluster.master_lb_enabled = True
        cluster.labels['master_lb_floating_ip_enabled'] = False
        self.config(health_openstack_fallback=False, group='kubernetes')

        self.k8s_monitor.poll_health_status()
        self.assertEqual(self.k8s_monitor.data['health_status'],
                         m_fields.ClusterHealthStatus.UNKNOWN)

    def test_is_magnum_auto_healer_running(self):
        cluster = self.k8s_monitor.cluster
        cluster.labels['auto_healing_enabled'] = True
        cluster.labels['auto_healing_controller'] = 'magnum-auto-healer'
        self.k8s_monitor._is_magnum_auto_healer_running()
        self.assertTrue(self.k8s_monitor._is_magnum_auto_healer_running())

        cluster.labels['auto_healing_enabled'] = False
        cluster.labels['auto_healing_controller'] = 'magnum-auto-healer'
        self.k8s_monitor._is_magnum_auto_healer_running()
        self.assertFalse(self.k8s_monitor._is_magnum_auto_healer_running())

        cluster.labels['auto_healing_enabled'] = True
        cluster.labels['auto_healing_controller'] = 'draino'
        self.k8s_monitor._is_magnum_auto_healer_running()
        self.assertFalse(self.k8s_monitor._is_magnum_auto_healer_running())

        cluster.labels = {}
        self.k8s_monitor._is_magnum_auto_healer_running()
        self.assertFalse(self.k8s_monitor._is_magnum_auto_healer_running())


def _server(name, status='ACTIVE'):
    server = mock.MagicMock(status=status)
    server.name = name
    return server


class K8sMonitorOpenStackHealthTestCase(base.TestCase):

    def setUp(self):
        super(K8sMonitorOpenStackHealthTestCase, self).setUp()
        cluster = utils.get_test_cluster(api_address='https://10.0.0.5:6443',
                                         floating_ip_enabled=False,
                                         labels={})
        self.cluster = objects.Cluster(self.context, **cluster)
        self.monitor = k8s_monitor.K8sMonitor(self.context, self.cluster)
        k8s_monitor._api_lb_ids.clear()
        k8s_monitor._stack_names.clear()

        p = mock.patch('magnum.drivers.common.k8s_monitor.clients.'
                       'OpenStackClients')
        self.osc = p.start().return_value
        self.addCleanup(p.stop)
        p = mock.patch('magnum.objects.NodeGroup.list')
        self.ng_list = p.start()
        self.addCleanup(p.stop)
        p = mock.patch('magnum.conductor.k8s_api.create_k8s_api')
        self.create_k8s_api = p.start()
        self.addCleanup(p.stop)

        self.ng_list.return_value = [
            mock.MagicMock(stack_id=self.cluster.stack_id)]
        self.heat = self.osc.heat.return_value
        self.heat.resources.get.side_effect = [
            mock.MagicMock(physical_resource_id='lb-stack-id'),
            mock.MagicMock(physical_resource_id='lb-id')]
        self.heat.stacks.get.return_value.stack_name = 'cluster1-abc123'
        self.octavia = self.osc.octavia.return_value
        self.octavia.load_balancer_show.return_value = {
            'operating_status': 'ONLINE'}
        self.nova = self.osc.nova.return_value
        self.nova.servers.list.return_value = [
            _server('cluster1-abc123-master-0'),
            _server('cluster1-abc123-node-0')]

    def _status(self):
        return (self.monitor.data['health_status'],
                self.monitor.data['health_status_reason'])

    def test_private_cluster_healthy_from_openstack(self):
        self.monitor.poll_health_status()

        self.assertEqual(
            (m_fields.ClusterHealthStatus.HEALTHY,
             {'api': 'The cluster cluster1 is not accessible.',
              'source': 'openstack',
              'loadbalancer': 'ONLINE',
              'cluster1-abc123-master-0.status': 'ACTIVE',
              'cluster1-abc123-node-0.status': 'ACTIVE'}),
            self._status())
        self.create_k8s_api.assert_not_called()
        self.heat.resources.get.assert_has_calls([
            mock.call(self.cluster.stack_id, 'api_lb'),
            mock.call('lb-stack-id', 'loadbalancer')])
        self.octavia.load_balancer_show.assert_called_once_with('lb-id')
        self.nova.servers.list.assert_called_once_with(search_opts={
            'all_tenants': True,
            'tenant_id': 'fake_project',
            'name': '^(cluster1-abc123)-'})
        self.assertNotIn('api_unreachable', self.monitor.data)

    def test_degraded_lb_is_unhealthy(self):
        self.octavia.load_balancer_show.return_value = {
            'operating_status': 'DEGRADED'}

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.UNHEALTHY, status)
        self.assertEqual('DEGRADED', reason['loadbalancer'])

    def test_lb_without_monitor_is_not_a_failure(self):
        self.octavia.load_balancer_show.return_value = {
            'operating_status': 'NO_MONITOR'}

        self.monitor.poll_health_status()

        self.assertEqual(m_fields.ClusterHealthStatus.HEALTHY,
                         self._status()[0])

    def test_stopped_server_is_unhealthy(self):
        self.nova.servers.list.return_value = [
            _server('cluster1-abc123-master-0'),
            _server('cluster1-abc123-node-0', 'SHUTOFF')]

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.UNHEALTHY, status)
        self.assertEqual('SHUTOFF', reason['cluster1-abc123-node-0.status'])

    def test_no_servers_is_unknown(self):
        self.nova.servers.list.return_value = []

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.UNKNOWN, status)
        self.assertEqual('no servers found', reason['openstack'])

    def test_lookup_failure_is_unknown(self):
        self.nova.servers.list.side_effect = Exception('nova down')

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.UNKNOWN, status)
        self.assertEqual('lookup failed', reason['openstack'])

    def test_no_master_lb_uses_servers_only(self):
        self.cluster.master_lb_enabled = False

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.HEALTHY, status)
        self.assertNotIn('loadbalancer', reason)
        self.heat.resources.get.assert_not_called()

    def test_missing_api_lb_resource_uses_servers_only(self):
        self.heat.resources.get.side_effect = heat_exc.HTTPNotFound()

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.HEALTHY, status)
        self.assertNotIn('loadbalancer', reason)

    def test_lb_id_and_stack_name_are_cached(self):
        self.monitor.poll_health_status()
        k8s_monitor.K8sMonitor(self.context,
                               self.cluster).poll_health_status()

        self.assertEqual(2, self.heat.resources.get.call_count)
        self.assertEqual(1, self.heat.stacks.get.call_count)
        self.assertEqual(2, self.octavia.load_balancer_show.call_count)

    def test_octavia_failure_evicts_cached_lb(self):
        self.octavia.load_balancer_show.side_effect = Exception('gone')

        self.monitor.poll_health_status()

        self.assertEqual(m_fields.ClusterHealthStatus.UNKNOWN,
                         self._status()[0])
        self.assertNotIn(self.cluster.uuid, k8s_monitor._api_lb_ids)

    def test_nodegroup_stacks_are_included(self):
        self.ng_list.return_value = [
            mock.MagicMock(stack_id=self.cluster.stack_id),
            mock.MagicMock(stack_id='ng-stack-id'),
            mock.MagicMock(stack_id=None)]
        names = {self.cluster.stack_id: mock.MagicMock(
                     stack_name='cluster1-abc123'),
                 'ng-stack-id': mock.MagicMock(
                     stack_name='cluster1-gpu-def456')}
        self.heat.stacks.get.side_effect = names.get

        self.monitor.poll_health_status()

        pattern = self.nova.servers.list.call_args[1]['search_opts']['name']
        self.assertEqual(
            '^(%s)-' % '|'.join(
                names[s].stack_name for s in sorted(names)),
            pattern)

    def _public_cluster_api_error(self, error):
        self.cluster.floating_ip_enabled = True
        api_client = self.create_k8s_api.return_value.api_client
        api_client.call_api.side_effect = error

    def test_firewalled_public_cluster_falls_back(self):
        self._public_cluster_api_error(
            urllib3.exceptions.ConnectTimeoutError('timed out'))

        self.monitor.poll_health_status()

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.HEALTHY, status)
        self.assertEqual(
            'Kubernetes API unreachable from Magnum (ConnectTimeoutError).',
            reason['api'])
        self.assertTrue(self.monitor.data['api_unreachable'])
        self.create_k8s_api.assert_called_once_with(
            self.context, self.cluster, retries=False)

    def test_tls_failure_counts_as_unreachable(self):
        self._public_cluster_api_error(
            k8s_rest.ApiException(status=0, reason='SSLError'))

        self.monitor.poll_health_status()

        self.assertTrue(self.monitor.data['api_unreachable'])
        self.assertEqual('openstack',
                         self._status()[1]['source'])

    def test_api_http_error_is_still_unhealthy(self):
        error = k8s_rest.ApiException(status=500, reason='Internal')
        error.body = '[-]etcd failed'
        self._public_cluster_api_error(error)

        self.monitor.poll_health_status()

        self.assertEqual(
            (m_fields.ClusterHealthStatus.UNHEALTHY,
             {'api': '[-]etcd failed'}),
            self._status())
        self.assertNotIn('api_unreachable', self.monitor.data)
        self.nova.servers.list.assert_not_called()

    def test_unreachable_without_fallback_raises(self):
        self.config(health_openstack_fallback=False, group='kubernetes')
        self._public_cluster_api_error(OSError('Connection refused'))

        self.assertRaises(k8s_monitor.ClusterUnreachable,
                          self.monitor.poll_health_status)

    def test_skip_api_reports_openstack_health(self):
        self.cluster.floating_ip_enabled = True

        self.monitor.poll_health_status(skip_api=True)

        status, reason = self._status()
        self.assertEqual(m_fields.ClusterHealthStatus.HEALTHY, status)
        self.assertEqual(
            'Kubernetes API unreachable from Magnum (backed off).',
            reason['api'])
        self.create_k8s_api.assert_not_called()

    def test_auto_healer_cluster_is_left_alone(self):
        self.cluster.labels = {
            'auto_healing_enabled': 'true',
            'auto_healing_controller': 'magnum-auto-healer'}

        self.monitor.poll_health_status()

        self.assertNotIn('health_status', self.monitor.data)
        self.osc.nova.assert_not_called()
