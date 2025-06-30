# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import mock
from mock import patch

from heatclient import exc as heatexc

import magnum.conf
from magnum.drivers.heat import driver as heat_driver
from magnum.drivers.k8s_fedora_atomic_v1 import driver as k8s_atomic_dr
from magnum import objects
from magnum.objects.fields import ClusterStatus as cluster_status
from magnum.tests import base
from magnum.tests.unit.db import utils

CONF = magnum.conf.CONF


class TestHeatPoller(base.TestCase):

    def setUp(self):
        super(TestHeatPoller, self).setUp()
        self.mock_stacks = dict()
        self.def_ngs = list()

    def _create_nodegroup(self, cluster, uuid, stack_id, name=None, role=None,
                          is_default=False, stack_status=None,
                          status_reason=None, stack_params=None,
                          stack_missing=False):
        """Create a new nodegroup

        Util that creates a new non-default ng, adds it to the cluster
        and creates the corresponding mock stack.
        """
        role = 'worker' if role is None else role
        ng = mock.MagicMock(uuid=uuid, role=role, is_default=is_default,
                            stack_id=stack_id)
        if name is not None:
            type(ng).name = name

        cluster.nodegroups.append(ng)

        if stack_status is None:
            stack_status = cluster_status.CREATE_COMPLETE

        if status_reason is None:
            status_reason = 'stack created'

        stack_params = dict() if stack_params is None else stack_params

        stack = mock.MagicMock(stack_status=stack_status,
                               stack_status_reason=status_reason,
                               parameters=stack_params)
        # In order to simulate a stack not found from osc we don't add the
        # stack in the dict.
        if not stack_missing:
            self.mock_stacks.update({stack_id: stack})
        else:
            # In case the stack is missing we need
            # to set the status to the ng, so that
            # _sync_missing_heat_stack knows which
            # was the previous state.
            ng.status = stack_status

        return ng

    @patch('magnum.conductor.utils.retrieve_cluster_template')
    @patch('oslo_config.cfg')
    @patch('magnum.common.clients.OpenStackClients')
    @patch('magnum.drivers.common.driver.Driver.get_driver')
    def setup_poll_test(self, mock_driver, mock_openstack_client, cfg,
                        mock_retrieve_cluster_template,
                        default_stack_status=None, status_reason=None,
                        stack_params=None, stack_missing=False):
        cfg.CONF.cluster_heat.max_attempts = 10

        if default_stack_status is None:
            default_stack_status = cluster_status.CREATE_COMPLETE

        cluster = mock.MagicMock(nodegroups=list())

        def_worker = self._create_nodegroup(cluster, 'worker_ng', 'stack1',
                                            name='worker_ng', role='worker',
                                            is_default=True,
                                            stack_status=default_stack_status,
                                            status_reason=status_reason,
                                            stack_params=stack_params,
                                            stack_missing=stack_missing)
        def_master = self._create_nodegroup(cluster, 'master_ng', 'stack1',
                                            name='master_ng', role='master',
                                            is_default=True,
                                            stack_status=default_stack_status,
                                            status_reason=status_reason,
                                            stack_params=stack_params,
                                            stack_missing=stack_missing)

        cluster.default_ng_worker = def_worker
        cluster.default_ng_master = def_master

        self.def_ngs = [def_worker, def_master]

        def get_ng_stack(stack_id, resolve_outputs=False):
            try:
                return self.mock_stacks[stack_id]
            except KeyError:
                # In this case we intentionally didn't add the stack
                # to the mock_stacks dict to simulte a not found error.
                # For this reason raise heat NotFound exception.
                raise heatexc.NotFound("stack not found")

        cluster_template_dict = utils.get_test_cluster_template(
            coe='kubernetes')
        mock_heat_client = mock.MagicMock()
        mock_heat_client.stacks.get = get_ng_stack
        mock_openstack_client.heat.return_value = mock_heat_client
        cluster_template = objects.ClusterTemplate(self.context,
                                                   **cluster_template_dict)
        mock_retrieve_cluster_template.return_value = cluster_template
        mock_driver.return_value = k8s_atomic_dr.Driver()
        poller = heat_driver.HeatPoller(mock_openstack_client,
                                        mock.MagicMock(), cluster,
                                        k8s_atomic_dr.Driver())
        poller.get_version_info = mock.MagicMock()
        return (cluster, poller)

    def test_poll_and_check_creating(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.CREATE_IN_PROGRESS)

        cluster.status = cluster_status.CREATE_IN_PROGRESS
        poller.poll_and_check()

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.CREATE_IN_PROGRESS, ng.status)

        self.assertEqual(cluster_status.CREATE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_create_complete(self):
        cluster, poller = self.setup_poll_test()

        cluster.status = cluster_status.CREATE_IN_PROGRESS
        poller.poll_and_check()

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.CREATE_COMPLETE, ng.status)
            self.assertEqual('stack created', ng.status_reason)
            self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_create_failed(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.CREATE_FAILED)

        cluster.status = cluster_status.CREATE_IN_PROGRESS
        self.assertIsNone(poller.poll_and_check())

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.CREATE_FAILED, ng.status)
            # Two calls to save since the stack ouptputs are synced too.
            self.assertEqual(2, ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_updating(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.UPDATE_IN_PROGRESS)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, ng.status)
            self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_update_complete(self):
        stack_params = {
            'number_of_minions': 2,
            'number_of_masters': 1
        }
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.UPDATE_COMPLETE,
            stack_params=stack_params)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        self.assertIsNone(poller.poll_and_check())

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.UPDATE_COMPLETE, ng.status)

        self.assertEqual(2, cluster.default_ng_worker.save.call_count)
        self.assertEqual(2, cluster.default_ng_master.save.call_count)
        self.assertEqual(2, cluster.default_ng_worker.node_count)
        self.assertEqual(1, cluster.default_ng_master.node_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_update_failed(self):
        stack_params = {
            'number_of_minions': 2,
            'number_of_masters': 1
        }
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.UPDATE_FAILED,
            stack_params=stack_params)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.UPDATE_FAILED, ng.status)
            # We have several calls to save because the stack outputs are
            # stored too.
            self.assertEqual(3, ng.save.call_count)

        self.assertEqual(2, cluster.default_ng_worker.node_count)
        self.assertEqual(1, cluster.default_ng_master.node_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_deleting(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.DELETE_IN_PROGRESS)

        cluster.status = cluster_status.DELETE_IN_PROGRESS
        poller.poll_and_check()

        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.DELETE_IN_PROGRESS, ng.status)
            # We have two calls to save because the stack outputs are
            # stored too.
            self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.DELETE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_deleted(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.DELETE_COMPLETE)

        cluster.status = cluster_status.DELETE_IN_PROGRESS
        self.assertIsNone(poller.poll_and_check())

        self.assertEqual(cluster_status.DELETE_COMPLETE,
                         cluster.default_ng_worker.status)
        self.assertEqual(1, cluster.default_ng_worker.save.call_count)
        self.assertEqual(0, cluster.default_ng_worker.destroy.call_count)

        self.assertEqual(cluster_status.DELETE_COMPLETE,
                         cluster.default_ng_master.status)
        self.assertEqual(1, cluster.default_ng_master.save.call_count)
        self.assertEqual(0, cluster.default_ng_master.destroy.call_count)

        self.assertEqual(cluster_status.DELETE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)
        self.assertEqual(0, cluster.destroy.call_count)

    def test_poll_and_check_delete_failed(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.DELETE_FAILED)

        cluster.status = cluster_status.DELETE_IN_PROGRESS
        poller.poll_and_check()

        self.assertEqual(cluster_status.DELETE_FAILED,
                         cluster.default_ng_worker.status)
        # We have two calls to save because the stack outputs are
        # stored too.
        self.assertEqual(2, cluster.default_ng_worker.save.call_count)
        self.assertEqual(0, cluster.default_ng_worker.destroy.call_count)

        self.assertEqual(cluster_status.DELETE_FAILED,
                         cluster.default_ng_master.status)
        # We have two calls to save because the stack outputs are
        # stored too.
        self.assertEqual(2, cluster.default_ng_master.save.call_count)
        self.assertEqual(0, cluster.default_ng_master.destroy.call_count)

        self.assertEqual(cluster_status.DELETE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)
        self.assertEqual(0, cluster.destroy.call_count)

    def test_poll_done_rollback_complete(self):
        stack_params = {
            'number_of_minions': 1,
            'number_of_masters': 1
        }
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.ROLLBACK_COMPLETE,
            stack_params=stack_params)

        self.assertIsNone(poller.poll_and_check())

        self.assertEqual(1, cluster.save.call_count)
        self.assertEqual(cluster_status.ROLLBACK_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.default_ng_worker.node_count)
        self.assertEqual(1, cluster.default_ng_master.node_count)

    def test_poll_done_rollback_failed(self):
        stack_params = {
            'number_of_minions': 1,
            'number_of_masters': 1
        }
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.ROLLBACK_FAILED,
            stack_params=stack_params)

        self.assertIsNone(poller.poll_and_check())

        self.assertEqual(1, cluster.save.call_count)
        self.assertEqual(cluster_status.ROLLBACK_FAILED, cluster.status)
        self.assertEqual(1, cluster.default_ng_worker.node_count)
        self.assertEqual(1, cluster.default_ng_master.node_count)

    def test_poll_and_check_new_ng_creating(self):
        cluster, poller = self.setup_poll_test()

        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.CREATE_IN_PROGRESS)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_IN_PROGRESS, ng.status)
        self.assertEqual(1, ng.save.call_count)
        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_created(self):
        cluster, poller = self.setup_poll_test()

        ng = self._create_nodegroup(cluster, 'ng1', 'stack2')

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_COMPLETE, ng.status)
        self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_create_failed(self):
        cluster, poller = self.setup_poll_test()

        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.CREATE_FAILED,
            status_reason='stack failed')

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual('stack created', def_ng.status_reason)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_FAILED, ng.status)
        self.assertEqual('stack failed', ng.status_reason)
        self.assertEqual(2, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_updated(self):
        cluster, poller = self.setup_poll_test()

        stack_params = {'number_of_minions': 3}
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.UPDATE_COMPLETE,
            stack_params=stack_params)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, ng.status)
        self.assertEqual(3, ng.node_count)
        self.assertEqual(2, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_update_failed(self):
        cluster, poller = self.setup_poll_test()

        stack_params = {'number_of_minions': 3}
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.UPDATE_FAILED,
            stack_params=stack_params)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, ng.status)
        self.assertEqual(3, ng.node_count)
        self.assertEqual(3, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_deleting(self):
        cluster, poller = self.setup_poll_test()

        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.DELETE_IN_PROGRESS)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.DELETE_IN_PROGRESS, ng.status)
        self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_deleted(self):
        cluster, poller = self.setup_poll_test()

        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.DELETE_COMPLETE)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(1, ng.destroy.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_delete_failed(self):
        cluster, poller = self.setup_poll_test()

        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.DELETE_FAILED)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.DELETE_FAILED, ng.status)
        self.assertEqual(2, ng.save.call_count)
        self.assertEqual(0, ng.destroy.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_rollback_complete(self):
        cluster, poller = self.setup_poll_test()

        stack_params = {
            'number_of_minions': 2,
            'number_of_masters': 0
        }
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.ROLLBACK_COMPLETE,
            stack_params=stack_params)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.ROLLBACK_COMPLETE, ng.status)
        self.assertEqual(2, ng.node_count)
        self.assertEqual(3, ng.save.call_count)
        self.assertEqual(0, ng.destroy.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_new_ng_rollback_failed(self):
        cluster, poller = self.setup_poll_test()

        stack_params = {
            'number_of_minions': 2,
            'number_of_masters': 0
        }
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.ROLLBACK_FAILED,
            stack_params=stack_params)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.ROLLBACK_FAILED, ng.status)
        self.assertEqual(2, ng.node_count)
        self.assertEqual(3, ng.save.call_count)
        self.assertEqual(0, ng.destroy.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_multiple_new_ngs(self):
        cluster, poller = self.setup_poll_test()

        ng1 = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.CREATE_COMPLETE)
        ng2 = self._create_nodegroup(
            cluster, 'ng2', 'stack3',
            stack_status=cluster_status.UPDATE_IN_PROGRESS)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_COMPLETE, ng1.status)
        self.assertEqual(1, ng1.save.call_count)
        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, ng2.status)
        self.assertEqual(1, ng2.save.call_count)

        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_multiple_ngs_failed_and_updating(self):
        cluster, poller = self.setup_poll_test()

        ng1 = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.CREATE_FAILED)
        ng2 = self._create_nodegroup(
            cluster, 'ng2', 'stack3',
            stack_status=cluster_status.UPDATE_IN_PROGRESS)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
            self.assertEqual(1, def_ng.save.call_count)

        self.assertEqual(cluster_status.CREATE_FAILED, ng1.status)
        self.assertEqual(2, ng1.save.call_count)
        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, ng2.status)
        self.assertEqual(1, ng2.save.call_count)

        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    @patch('magnum.drivers.heat.driver.trust_manager')
    @patch('magnum.drivers.heat.driver.cert_manager')
    def test_delete_complete(self, cert_manager, trust_manager):
        cluster, poller = self.setup_poll_test()
        poller._delete_complete()
        self.assertEqual(
            1, cert_manager.delete_certificates_from_cluster.call_count)
        self.assertEqual(1, trust_manager.delete_trustee_and_trust.call_count)

    @patch('magnum.drivers.heat.driver.LOG')
    def test_nodegroup_failed(self, logger):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.CREATE_FAILED)

        self._create_nodegroup(cluster, 'ng1', 'stack2',
                               stack_status=cluster_status.CREATE_FAILED)
        poller.poll_and_check()
        # Verify that we have one log for each failed nodegroup
        self.assertEqual(3, logger.error.call_count)

    def test_stack_not_found_creating(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.CREATE_IN_PROGRESS,
            stack_missing=True)
        poller.poll_and_check()
        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.CREATE_FAILED, ng.status)

    def test_stack_not_found_updating(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.UPDATE_IN_PROGRESS,
            stack_missing=True)
        poller.poll_and_check()
        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.UPDATE_FAILED, ng.status)

    def test_stack_not_found_deleting(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.DELETE_IN_PROGRESS,
            stack_missing=True)
        poller.poll_and_check()
        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.DELETE_COMPLETE, ng.status)

    def test_stack_not_found_new_ng_creating(self):
        cluster, poller = self.setup_poll_test()
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.CREATE_IN_PROGRESS, stack_missing=True)
        poller.poll_and_check()
        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
        self.assertEqual(cluster_status.CREATE_FAILED, ng.status)

    def test_stack_not_found_new_ng_updating(self):
        cluster, poller = self.setup_poll_test()
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.UPDATE_IN_PROGRESS, stack_missing=True)
        poller.poll_and_check()
        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
        self.assertEqual(cluster_status.UPDATE_FAILED, ng.status)

    def test_stack_not_found_new_ng_deleting(self):
        cluster, poller = self.setup_poll_test()
        ng = self._create_nodegroup(
            cluster, 'ng1', 'stack2',
            stack_status=cluster_status.DELETE_IN_PROGRESS, stack_missing=True)
        poller.poll_and_check()
        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.CREATE_COMPLETE, def_ng.status)
        self.assertEqual(cluster_status.DELETE_COMPLETE, ng.status)

    def test_poll_and_check_failed_default_ng(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.UPDATE_FAILED)

        ng = self._create_nodegroup(
            cluster, 'ng', 'stack2',
            stack_status=cluster_status.UPDATE_COMPLETE)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.UPDATE_FAILED, def_ng.status)
            self.assertEqual(2, def_ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, ng.status)
        self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_rollback_failed_default_ng(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.ROLLBACK_FAILED)

        ng = self._create_nodegroup(
            cluster, 'ng', 'stack2',
            stack_status=cluster_status.UPDATE_COMPLETE)

        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.ROLLBACK_FAILED, def_ng.status)
            self.assertEqual(2, def_ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_COMPLETE, ng.status)
        self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.UPDATE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_rollback_failed_def_ng(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.DELETE_FAILED)

        ng = self._create_nodegroup(
            cluster, 'ng', 'stack2',
            stack_status=cluster_status.DELETE_IN_PROGRESS)

        cluster.status = cluster_status.DELETE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.DELETE_FAILED, def_ng.status)
            self.assertEqual(2, def_ng.save.call_count)

        self.assertEqual(cluster_status.DELETE_IN_PROGRESS, ng.status)
        self.assertEqual(1, ng.save.call_count)

        self.assertEqual(cluster_status.DELETE_IN_PROGRESS, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

    def test_poll_and_check_delete_failed_def_ng(self):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.DELETE_FAILED)

        ng = self._create_nodegroup(
            cluster, 'ng', 'stack2',
            stack_status=cluster_status.DELETE_COMPLETE)

        cluster.status = cluster_status.DELETE_IN_PROGRESS
        poller.poll_and_check()

        for def_ng in self.def_ngs:
            self.assertEqual(cluster_status.DELETE_FAILED, def_ng.status)
            self.assertEqual(2, def_ng.save.call_count)

        # Check that the non-default ng was deleted
        self.assertEqual(1, ng.destroy.call_count)

        self.assertEqual(cluster_status.DELETE_FAILED, cluster.status)
        self.assertEqual(1, cluster.save.call_count)

        self.assertIn('worker_ng', cluster.status_reason)
        self.assertIn('master_ng', cluster.status_reason)


class TestHeatDriverResize(base.TestCase):
    """Test cases for the resize functionality with master-0 updates."""

    def setUp(self):
        super(TestHeatDriverResize, self).setUp()

    @patch('magnum.common.clients.OpenStackClients')
    @patch('magnum.drivers.heat.driver.HeatDriver.get_template_definition')
    def test_resize_stack_master_scaledown_updates_master_0(self, mock_get_template_def, mock_osc_class):
        """Test that master scaledown triggers update to master-0 for etcd cleanup."""
        # Setup mocks
        mock_osc = mock.MagicMock()
        mock_osc_class.return_value = mock_osc
        
        mock_heat_client = mock.MagicMock()
        mock_osc.heat.return_value = mock_heat_client
        
        # Mock the stack get operations
        scaled_stack = mock.MagicMock()
        scaled_stack.parameters = {'timestamp_upgrade': '2023-01-01T00:00:00'}
        
        master_0_stack = mock.MagicMock()
        master_0_stack.parameters = {
            'timestamp_upgrade': '2023-01-01T00:00:00',
            'discovery_url': 'http://discovery.example.com',
            'cluster_uuid': 'test-cluster-uuid'
        }
        
        def mock_stack_get(stack_id):
            if stack_id == 'scaled_master_stack_id':
                return scaled_stack
            elif stack_id == 'default_master_stack_id':
                return master_0_stack
            else:
                raise Exception(f"Unexpected stack_id: {stack_id}")
        
        mock_heat_client.stacks.get = mock_stack_get
        
        # Mock template definition
        mock_template_def = mock.MagicMock()
        mock_template_def.get_scale_params.side_effect = [
            # First call for the scaled nodegroup
            {'number_of_masters': 2, 'masters_to_remove': ['master-2']},
            # Second call for the default master nodegroup  
            {'number_of_masters': 3}  # Current count before scaling
        ]
        mock_get_template_def.return_value = mock_template_def
        
        # Create test objects
        driver = heat_driver.HeatDriver()
        
        cluster = mock.MagicMock()
        default_master_ng = mock.MagicMock()
        default_master_ng.uuid = 'default_master_uuid'
        default_master_ng.stack_id = 'default_master_stack_id'
        default_master_ng.node_count = 3
        cluster.default_ng_master = default_master_ng
        
        scaled_master_ng = mock.MagicMock()
        scaled_master_ng.uuid = 'scaled_master_uuid'  # Different from default
        scaled_master_ng.stack_id = 'scaled_master_stack_id'
        scaled_master_ng.role = 'master'
        scaled_master_ng.node_count = 2
        
        resize_manager = mock.MagicMock()
        nodes_to_remove = ['master-2']
        
        # Execute the resize operation
        driver._resize_stack(
            context=mock.MagicMock(),
            cluster=cluster,
            resize_manager=resize_manager,
            node_count=2,
            nodes_to_remove=nodes_to_remove,
            nodegroup=scaled_master_ng,
            rollback=False
        )
        
        # Verify that both stacks were updated
        self.assertEqual(2, mock_heat_client.stacks.update.call_count)
        
        # Verify the calls
        call_args_list = mock_heat_client.stacks.update.call_args_list
        
        # First call should be the main resize
        first_call = call_args_list[0]
        self.assertEqual('scaled_master_stack_id', first_call[0][0])
        
        # Second call should be the master-0 update
        second_call = call_args_list[1]  
        self.assertEqual('default_master_stack_id', second_call[0][0])
        
        # Check that the master-0 update includes the new master count
        master_0_params = second_call[1]['parameters']
        self.assertEqual(2, master_0_params['number_of_masters'])
        self.assertEqual(False, master_0_params['is_upgrade'])
        
        # Check that existing parameters were preserved
        self.assertEqual('2023-01-01T00:00:00', master_0_params['timestamp_upgrade'])
        self.assertEqual('http://discovery.example.com', master_0_params['discovery_url'])
        self.assertEqual('test-cluster-uuid', master_0_params['cluster_uuid'])

    @patch('magnum.common.clients.OpenStackClients')
    @patch('magnum.drivers.heat.driver.HeatDriver.get_template_definition')
    def test_resize_stack_master_scaledown_same_nodegroup_no_extra_update(self, mock_get_template_def, mock_osc_class):
        """Test that no extra update is triggered when scaling the default master nodegroup."""
        # Setup mocks
        mock_osc = mock.MagicMock()
        mock_osc_class.return_value = mock_osc
        
        mock_heat_client = mock.MagicMock()
        mock_osc.heat.return_value = mock_heat_client
        
        # Mock the stack get operation
        stack = mock.MagicMock()
        stack.parameters = {'timestamp_upgrade': '2023-01-01T00:00:00'}
        mock_heat_client.stacks.get.return_value = stack
        
        # Mock template definition
        mock_template_def = mock.MagicMock()
        mock_template_def.get_scale_params.return_value = {
            'number_of_masters': 2, 
            'masters_to_remove': ['master-2']
        }
        mock_get_template_def.return_value = mock_template_def
        
        # Create test objects - same nodegroup is both scaled and default
        driver = heat_driver.HeatDriver()
        
        cluster = mock.MagicMock()
        default_master_ng = mock.MagicMock()
        default_master_ng.uuid = 'default_master_uuid'
        default_master_ng.stack_id = 'default_master_stack_id'
        default_master_ng.role = 'master'
        default_master_ng.node_count = 2
        cluster.default_ng_master = default_master_ng
        
        resize_manager = mock.MagicMock()
        nodes_to_remove = ['master-2']
        
        # Execute the resize operation
        driver._resize_stack(
            context=mock.MagicMock(),
            cluster=cluster,
            resize_manager=resize_manager,
            node_count=2,
            nodes_to_remove=nodes_to_remove,
            nodegroup=default_master_ng,  # Same as default
            rollback=False
        )
        
        # Verify that only one stack update was called (no extra update for master-0)
        self.assertEqual(1, mock_heat_client.stacks.update.call_count)
        
        # Verify the call was for the correct stack
        call_args = mock_heat_client.stacks.update.call_args_list[0]
        self.assertEqual('default_master_stack_id', call_args[0][0])

    @patch('magnum.common.clients.OpenStackClients')
    @patch('magnum.drivers.heat.driver.HeatDriver.get_template_definition')
    def test_resize_stack_worker_no_master_0_update(self, mock_get_template_def, mock_osc_class):
        """Test that worker resize does not trigger master-0 updates."""
        # Setup mocks
        mock_osc = mock.MagicMock()
        mock_osc_class.return_value = mock_osc
        
        mock_heat_client = mock.MagicMock()
        mock_osc.heat.return_value = mock_heat_client
        
        # Mock the stack get operation
        stack = mock.MagicMock()
        stack.parameters = {}
        mock_heat_client.stacks.get.return_value = stack
        
        # Mock template definition
        mock_template_def = mock.MagicMock()
        mock_template_def.get_scale_params.return_value = {
            'number_of_minions': 3, 
            'minions_to_remove': ['worker-3']
        }
        mock_get_template_def.return_value = mock_template_def
        
        # Create test objects
        driver = heat_driver.HeatDriver()
        
        cluster = mock.MagicMock()
        worker_ng = mock.MagicMock()
        worker_ng.uuid = 'worker_uuid'
        worker_ng.stack_id = 'worker_stack_id'
        worker_ng.role = 'worker'  # Not master
        worker_ng.node_count = 3
        
        resize_manager = mock.MagicMock()
        nodes_to_remove = ['worker-3']
        
        # Execute the resize operation
        driver._resize_stack(
            context=mock.MagicMock(),
            cluster=cluster,
            resize_manager=resize_manager,
            node_count=3,
            nodes_to_remove=nodes_to_remove,
            nodegroup=worker_ng,
            rollback=False
        )
        
        # Verify that only one stack update was called (no master-0 update for worker resize)
        self.assertEqual(1, mock_heat_client.stacks.update.call_count)
        
        # Verify the call was for the worker stack
        call_args = mock_heat_client.stacks.update.call_args_list[0]
        self.assertEqual('worker_stack_id', call_args[0][0])
