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

import base64
import json
from unittest import mock
from unittest.mock import patch

from heatclient import exc as heatexc
from oslo_utils import uuidutils

from magnum.common import exception
import magnum.conf
from magnum.drivers.heat import driver as heat_driver
from magnum.drivers.heat import k8s_template_def as k8s_tdef
from magnum.drivers.heat import template_def as heat_tdef
from magnum.drivers.k8s_fedora_coreos_v1 import driver as k8s_coreos_dr
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

        cluster = mock.MagicMock(nodegroups=list(),
                                 uuid=uuidutils.generate_uuid())

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
        mock_driver.return_value = k8s_coreos_dr.Driver()
        poller = heat_driver.HeatPoller(mock_openstack_client,
                                        mock.MagicMock(), cluster,
                                        k8s_coreos_dr.Driver())
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

    def _member_update_poll(self, member_status):
        cluster, poller = self.setup_poll_test(
            default_stack_status=cluster_status.UPDATE_COMPLETE,
            stack_params={'number_of_minions': 2, 'number_of_masters': 1})
        member = mock.MagicMock(resource_name='0',
                                resource_type='kubemaster.yaml',
                                physical_resource_id='member0',
                                resource_status=cluster_status.UPDATE_COMPLETE)
        group = mock.MagicMock(resource_name='kube_masters',
                               resource_type='OS::Heat::ResourceGroup',
                               physical_resource_id='group0',
                               resource_status=cluster_status.UPDATE_COMPLETE)
        heat = poller.openstack_client.heat.return_value
        heat.resources.list.return_value = [group, member]
        self.mock_stacks['member0'] = mock.MagicMock(
            stack_status=member_status)
        cluster.status = cluster_status.UPDATE_IN_PROGRESS
        poller.poll_and_check()
        return cluster

    def test_poll_and_check_member_stack_updating_holds(self):
        cluster = self._member_update_poll(cluster_status.UPDATE_IN_PROGRESS)
        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, ng.status)
        self.assertEqual(cluster_status.UPDATE_IN_PROGRESS, cluster.status)

    def test_poll_and_check_member_stack_complete_releases(self):
        cluster = self._member_update_poll(cluster_status.UPDATE_COMPLETE)
        for ng in cluster.nodegroups:
            self.assertEqual(cluster_status.UPDATE_COMPLETE, ng.status)
        self.assertEqual(cluster_status.UPDATE_COMPLETE, cluster.status)

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


class DummyKubernetesDriver(heat_driver.KubernetesDriver):

    def __init__(self):
        super(DummyKubernetesDriver, self).__init__()
        self.definition = mock.MagicMock()

    @property
    def provides(self):
        return []

    def get_template_definition(self):
        return self.definition

    def get_nodegroup_extra_params(self, cluster, osc):
        return {}

    def upgrade_cluster(self, context, cluster, cluster_template,
                        max_batch_size, nodegroup, scale_manager=None,
                        rollback=False):
        raise NotImplementedError


class TestHeatDriverResizeFlags(base.TestCase):

    def test_get_merged_stack_parameters_omits_masked_values(self):
        driver = DummyKubernetesDriver()
        osc = mock.MagicMock()
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={
                'number_of_masters': 1,
                'password': '******',
                'kube_service_account_private_key': '******',
                'plain': 'value',
            })

        merged = driver._get_merged_stack_parameters(
            osc, 'stack-id', {'number_of_masters': 2})

        self.assertEqual(2, merged['number_of_masters'])
        self.assertEqual('value', merged['plain'])
        self.assertNotIn('password', merged)
        self.assertNotIn('kube_service_account_private_key', merged)

    def test_get_nested_ca_rotation_params_skips_masked_values(self):
        driver = DummyKubernetesDriver()
        nodegroup = mock.MagicMock(role='worker')

        nested = driver._get_nested_ca_rotation_params(
            nodegroup,
            {
                'ca_rotation_id': 'rotation-id',
                'kube_service_account_key': 'public-key',
                'kube_service_account_private_key': 'private-key',
                'timestamp_upgrade': '2026-04-04T00:00:00',
            },
            {
                'trustee_user_id': 'trustee-user',
                'trustee_password': '******',
                'auth_url': 'https://keystone.example/v3',
                'kube_service_account_private_key': '******',
            })

        self.assertEqual('trustee-user', nested['trustee_user_id'])
        self.assertEqual('https://keystone.example/v3', nested['auth_url'])
        # CA rotation must NOT touch the service-account keypair: it is omitted
        # from the per-node params so a params-only `existing=True` update makes
        # Heat preserve each member's current value (keeping it in lockstep with
        # the unchanged parent stack, so masters added later still match).
        self.assertNotIn('kube_service_account_key', nested)
        self.assertNotIn('kube_service_account_private_key', nested)
        self.assertNotIn('trustee_password', nested)

    def test_get_ca_rotation_params_does_not_rotate_sa_keys(self):
        driver = DummyKubernetesDriver()
        cluster = mock.MagicMock(uuid='cluster-uuid', labels={})

        with mock.patch.object(driver, '_fetch_ca_key', return_value=None):
            params = driver._get_ca_rotation_params(mock.sentinel.ctx, cluster)

        self.assertIn('ca_rotation_id', params)
        self.assertTrue(params['ca_rotation_id'])
        self.assertNotIn('kube_service_account_key', params)
        self.assertNotIn('kube_service_account_private_key', params)

    @patch('magnum.drivers.heat.driver.x509.decrypt_key')
    @patch('magnum.drivers.heat.driver.cert_manager.get_cluster_ca_certificate')
    def test_fetch_ca_key_defaults_enabled(self, mock_get_ca, mock_decrypt):
        # cert_manager_api absent => treated as enabled, so a node added later
        # always renders the CURRENT CA key and never mismatches the live ca.crt.
        driver = DummyKubernetesDriver()
        ca_cert = mock.MagicMock()
        ca_cert.get_private_key_passphrase.return_value = b'pw'
        mock_get_ca.return_value = ca_cert
        mock_decrypt.return_value = 'KEY\nLINE2'
        cluster = mock.MagicMock(uuid='cluster-uuid', labels={})

        ca_key = driver._fetch_ca_key(mock.sentinel.ctx, cluster)

        self.assertEqual('KEY\\nLINE2', ca_key)
        mock_get_ca.assert_called_once()

    def test_fetch_ca_key_disabled_when_label_false(self):
        driver = DummyKubernetesDriver()
        cluster = mock.MagicMock(uuid='cluster-uuid',
                                 labels={'cert_manager_api': 'false'})

        self.assertIsNone(driver._fetch_ca_key(mock.sentinel.ctx, cluster))

    @patch('magnum.drivers.heat.driver.clients.OpenStackClients')
    def test_resize_stack_is_params_only_without_live_token(
            self, mock_osc_cls):
        driver = DummyKubernetesDriver()
        driver.definition.get_scale_params.return_value = {
            'number_of_minions': 2,
        }
        driver._get_stack_update_template_fields = mock.MagicMock(
            return_value={})

        osc = mock.MagicMock()
        mock_osc_cls.return_value = osc
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={
                'ca_rotation_id': 'stale-rotation-id',
                'number_of_minions': 1,
            })

        # Resize sends only the counts: the flags and ca_rotation_id are left
        # to existing: True. A token is carried only when a master member
        # holds one (see the in-flight test below).
        cluster = mock.MagicMock(uuid='cluster-uuid', nodegroups=[])
        nodegroup = mock.MagicMock(
            stack_id='worker-stack-id',
            role='worker',
            node_count=2,
            is_default=True)

        driver._resize_stack(mock.sentinel.ctx, cluster, None, 2, None,
                             nodegroup=nodegroup, rollback=False)

        _, update_kwargs = osc.heat.return_value.stacks.update.call_args
        self.assertEqual({'number_of_minions': 2},
                         update_kwargs['parameters'])

    @patch('magnum.drivers.heat.driver.clients.OpenStackClients')
    def test_resize_stack_preserves_in_flight_ca_rotation_id(self,
                                                             mock_osc_cls):
        # A rotation writes its token to the MEMBER stacks only. Clearing it
        # from a parent-driven update abandons the rotation mid-protocol: the
        # nodes stop, the desired phase never advances, and every peer waiting
        # at the dual-CA barrier burns its Heat timeout.
        driver = DummyKubernetesDriver()
        driver.definition.get_scale_params.return_value = {
            'number_of_minions': 2,
            'ca_rotation_id': '',
        }
        driver._get_stack_update_template_fields = mock.MagicMock(
            return_value={})

        osc = mock.MagicMock()
        mock_osc_cls.return_value = osc
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={
                'ca_rotation_id': 'live-rotation-id',
                'number_of_minions': 1,
            })

        nodegroup = mock.MagicMock(
            stack_id='worker-stack-id',
            role='worker',
            node_count=2,
            is_default=True)
        master = mock.MagicMock(stack_id='cluster-stack-id', role='master',
                                is_default=True)
        cluster = mock.MagicMock(uuid='cluster-uuid',
                                 stack_id='cluster-stack-id',
                                 nodegroups=[nodegroup, master])
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['member-0'])

        driver._resize_stack(mock.sentinel.ctx, cluster, None, 2, None,
                             nodegroup=nodegroup, rollback=False)

        _, update_kwargs = osc.heat.return_value.stacks.update.call_args
        self.assertEqual('live-rotation-id',
                         update_kwargs['parameters']['ca_rotation_id'])

    def test_live_ca_rotation_id_reads_master_members_only(self):
        # Every rotation includes all masters, so workers are never read:
        # on a large cluster that would be one Heat call per worker per update.
        driver = DummyKubernetesDriver()
        osc = mock.MagicMock()
        stacks = {
            'master-0': mock.MagicMock(parameters={'ca_rotation_id': ''}),
            'master-1': mock.MagicMock(
                parameters={'ca_rotation_id': 'from-master'}),
            'worker-0': mock.MagicMock(
                parameters={'ca_rotation_id': 'from-worker'}),
        }
        stacks_get = osc.heat.return_value.stacks.get
        stacks_get.side_effect = lambda sid, **_kw: stacks[sid]

        worker = mock.MagicMock(role='worker', stack_id='ng-stack',
                                is_default=False, name='pool')
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True, name='default-master')
        cluster = mock.MagicMock(uuid='cluster-uuid',
                                 stack_id='cluster-stack',
                                 nodegroups=[worker, master])
        driver._get_nested_stack_ids = mock.MagicMock(
            side_effect=lambda _osc, _parent, ng: (
                ['master-0', 'master-1'] if ng.role == 'master'
                else ['worker-0']))

        self.assertEqual('from-master',
                         driver._live_ca_rotation_id(osc, cluster))
        stacks_get.assert_has_calls([
            mock.call('master-0', resolve_outputs=False),
            mock.call('master-1', resolve_outputs=False),
        ])
        self.assertEqual(2, stacks_get.call_count)

        stacks['master-1'].parameters = {'ca_rotation_id': ''}
        self.assertEqual('', driver._live_ca_rotation_id(osc, cluster))

    def test_live_ca_rotation_id_is_best_effort(self):
        # Reading the token must never fail a cluster update.
        driver = DummyKubernetesDriver()
        osc = mock.MagicMock()
        osc.heat.return_value.stacks.get.side_effect = Exception('boom')
        nodegroup = mock.MagicMock(role='master', stack_id='cluster-stack',
                                   is_default=True, name='default-master')
        cluster = mock.MagicMock(uuid='cluster-uuid',
                                 stack_id='cluster-stack',
                                 nodegroups=[nodegroup])
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['member-0'])

        self.assertEqual('', driver._live_ca_rotation_id(osc, cluster))

    @patch('magnum.drivers.heat.driver.clients.OpenStackClients')
    def test_master_resize_cluster_update_sends_only_master_count(
            self, mock_osc_cls):
        driver = DummyKubernetesDriver()
        driver._get_stack_update_template_fields = mock.MagicMock(
            return_value={})

        osc = mock.MagicMock()
        mock_osc_cls.return_value = osc
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={
                'ca_rotation_id': 'stale-rotation-id',
                'number_of_masters': 1,
                'password': '******',
                'kube_service_account_private_key': '******',
            })

        default_master = mock.MagicMock(
            uuid='default-master',
            role='master',
            node_count=1,
            stack_id='cluster-stack-id')
        resized_master = mock.MagicMock(
            uuid='resized-master',
            role='master',
            node_count=2,
            stack_id='nodegroup-stack-id')
        cluster = mock.MagicMock(
            uuid='cluster-uuid',
            nodegroups=[default_master, resized_master],
            default_ng_master=default_master)

        driver._update_cluster_stack_for_master_resize(
            mock.sentinel.ctx, cluster, resized_master, {})

        _, update_kwargs = osc.heat.return_value.stacks.update.call_args
        self.assertEqual({'number_of_masters': 3},
                         update_kwargs['parameters'])


class TestMemberOwnedParams(base.TestCase):
    """Label reconfigure / CA rotation write to member stacks only; every
    parent-driven update must carry those values or it reverts them."""

    def _cluster(self, *nodegroups):
        master = next(ng for ng in nodegroups if ng.role == 'master')
        workers = [ng for ng in nodegroups
                   if ng.role == 'worker' and ng.is_default]
        return mock.MagicMock(uuid='cluster-uuid', stack_id='cluster-stack',
                              nodegroups=list(nodegroups),
                              default_ng_master=master,
                              default_ng_worker=workers[0] if workers
                              else None)

    @patch('magnum.drivers.heat.driver.clients.OpenStackClients')
    def test_resize_stack_carries_label_reconfigured_member_params(
            self, mock_osc_cls):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('kubeapi_options', 'metrics_server_enabled', 'kube_tag'))
        driver.definition.get_scale_params.return_value = {
            'number_of_minions': 2}
        osc = mock.MagicMock()
        mock_osc_cls.return_value = osc
        root = mock.MagicMock(parameters={
            'number_of_minions': 1, 'kubeapi_options': '',
            'metrics_server_enabled': 'false', 'timestamp_upgrade': '',
            'kube_tag': 'v1.30.0', 'ca_rotation_id': ''})
        member = mock.MagicMock(parameters={
            'kubeapi_options': '--oidc-client-id=headlamp',
            'metrics_server_enabled': 'true',
            'timestamp_upgrade': '2026-09-11T07:38:00',
            'kube_tag': 'v1.31.0', 'ca_rotation_id': ''})
        osc.heat.return_value.stacks.get.side_effect = (
            lambda sid, **kw: root if sid == 'cluster-stack' else member)
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        worker = mock.MagicMock(role='worker', stack_id='cluster-stack',
                                is_default=True, node_count=2)
        cluster = self._cluster(master, worker)
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['master-0'])

        driver._resize_stack(mock.sentinel.ctx, cluster, None, 2, None,
                             nodegroup=worker, rollback=False)

        _, kwargs = osc.heat.return_value.stacks.update.call_args
        params = kwargs['parameters']
        self.assertEqual('--oidc-client-id=headlamp',
                         params['kubeapi_options'])
        self.assertEqual('true', params['metrics_server_enabled'])
        self.assertEqual('2026-09-11T07:38:00', params['timestamp_upgrade'])
        self.assertNotIn('kube_tag', params)
        self.assertEqual(2, params['number_of_minions'])

    @patch('magnum.drivers.heat.driver.clients.OpenStackClients')
    def test_update_stack_carries_params_a_legacy_root_stack_lacks(
            self, mock_osc_cls):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('kubeapi_options', 'kube_files',
             'kube_scheduler_scoring_strategy'))
        driver.definition.get_scale_params.return_value = {
            'number_of_minions': 3}
        osc = mock.MagicMock()
        mock_osc_cls.return_value = osc
        legacy_root = mock.MagicMock(parameters={
            'number_of_minions': 2, 'kubeapi_options': '',
            'timestamp_upgrade': '', 'ca_rotation_id': ''})
        member = mock.MagicMock(parameters={
            'kubeapi_options': '--oidc-ca-file=/etc/kubernetes/files/oidc_ca',
            'kube_files': 'eyJvaWRjX2NhIjoiLS0tIn0=',
            'kube_scheduler_scoring_strategy': 'MostAllocated',
            'timestamp_upgrade': '', 'ca_rotation_id': ''})
        osc.heat.return_value.stacks.get.side_effect = (
            lambda sid, **kw: legacy_root if sid == 'cluster-stack'
            else member)
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        worker = mock.MagicMock(role='worker', stack_id='cluster-stack',
                                is_default=True, node_count=3)
        cluster = self._cluster(master, worker)
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['master-0'])
        driver._prepare_stack_for_template_update = mock.MagicMock()
        driver._get_stack_update_template_fields = mock.MagicMock(
            return_value={'template': {'parameters': {
                'number_of_minions': {}, 'kubeapi_options': {},
                'kube_files': {'default': ''},
                'kube_scheduler_scoring_strategy': {'default': ''}}},
                'environment_files': [], 'files': {}})

        driver._update_stack(mock.sentinel.ctx, cluster)

        _, kwargs = osc.heat.return_value.stacks.update.call_args
        params = kwargs['parameters']
        self.assertEqual('eyJvaWRjX2NhIjoiLS0tIn0=', params['kube_files'])
        self.assertEqual('MostAllocated',
                         params['kube_scheduler_scoring_strategy'])
        self.assertEqual('--oidc-ca-file=/etc/kubernetes/files/oidc_ca',
                         params['kubeapi_options'])

    def test_preserve_member_params_reads_the_target_nodegroup(self):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('kubelet_options',))
        osc = mock.MagicMock()
        stacks = {
            'pool-0': mock.MagicMock(parameters={
                'kubelet_options': '--max-pods=50',
                'timestamp_upgrade': 'T-pool'}),
            'master-0': mock.MagicMock(parameters={
                'kubelet_options': '--from-master', 'ca_rotation_id': ''}),
        }
        osc.heat.return_value.stacks.get.side_effect = (
            lambda sid, **kw: stacks[sid])
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        pool = mock.MagicMock(role='worker', stack_id='pool-stack',
                              is_default=False)
        cluster = self._cluster(master, pool)
        driver._get_nested_stack_ids = mock.MagicMock(
            side_effect=lambda _osc, _parent, ng: (
                ['pool-0'] if ng is pool else ['master-0']))
        target = {'kubelet_options': '', 'timestamp_upgrade': '',
                  'number_of_minions': 2}

        params = {'number_of_minions': 3}
        driver._preserve_member_params(mock.sentinel.ctx, osc, cluster,
                                       params, 'pool-stack', target)
        self.assertEqual('--max-pods=50', params['kubelet_options'])
        self.assertEqual('T-pool', params['timestamp_upgrade'])

        params = {'kubelet_options': '--explicit'}
        driver._preserve_member_params(mock.sentinel.ctx, osc, cluster,
                                       params, 'pool-stack', target)
        self.assertEqual('--explicit', params['kubelet_options'])

    def test_preserve_member_params_refreshes_hidden_ca_key(self):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset()
        driver._fetch_ca_key = mock.MagicMock(return_value='NEWKEY')
        driver._get_nested_stack_ids = mock.MagicMock(return_value=[])
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        cluster = self._cluster(master)

        params = {}
        driver._preserve_member_params(mock.sentinel.ctx, mock.MagicMock(),
                                       cluster, params, 'cluster-stack',
                                       {'ca_key': '******'})

        self.assertEqual('NEWKEY', params['ca_key'])
        driver._fetch_ca_key.assert_called_once_with(mock.sentinel.ctx,
                                                     cluster)

    def test_reconfigure_cluster_pushes_label_changes_without_rolling(self):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('kubeapi_options', 'kubelet_options', 'metrics_server_enabled',
             'kube_tag', 'etcd_volume_size'))
        driver._extract_template_definition = mock.MagicMock(
            return_value=(None, {
                'kubeapi_options': '--oidc-client-id=headlamp',
                'kubelet_options': '--max-pods=50',
                'metrics_server_enabled': 'true',
                'kube_tag': 'v1.31.0', 'etcd_volume_size': 20,
                'unset': None}, None))
        driver._get_nested_stack_update_template_fields = mock.MagicMock(
            return_value={'template': {}, 'files': {}})
        driver._clear_orphaned_software_deployments = mock.MagicMock()
        driver._config_backing_row_missing = mock.MagicMock(
            return_value=False)
        driver._get_update_timeout = mock.MagicMock(return_value=60)
        driver._filter_params_for_template = mock.MagicMock(
            side_effect=lambda params, template: params)
        osc = mock.MagicMock()
        driver._get_cluster_osc = mock.MagicMock(return_value=osc)
        stacks = {
            'master-0': mock.MagicMock(parameters={
                'kubeapi_options': '', 'kubelet_options': '',
                'metrics_server_enabled': 'false', 'kube_tag': 'v1.30.0',
                'etcd_volume_size': '10', 'timestamp_upgrade': 'T0',
                'ca_rotation_id': ''}),
            'worker-0': mock.MagicMock(parameters={
                'kubelet_options': '', 'kube_tag': 'v1.30.0',
                'timestamp_upgrade': 'T0', 'reconciler_version': ''}),
        }
        osc.heat.return_value.stacks.get.side_effect = (
            lambda sid, **kw: stacks[sid])
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        worker = mock.MagicMock(role='worker', stack_id='cluster-stack',
                                is_default=True)
        cluster = self._cluster(master, worker)
        driver._get_nested_stack_ids = mock.MagicMock(
            side_effect=lambda _osc, _parent, ng: (
                ['master-0'] if ng is master else ['worker-0']))

        driver.reconfigure_cluster(mock.sentinel.ctx, cluster)

        updates = {c[0][0]: c[1] for c in
                   osc.heat.return_value.stacks.update.call_args_list}
        master_params = updates['master-0']['parameters']
        self.assertEqual('--oidc-client-id=headlamp',
                         master_params['kubeapi_options'])
        self.assertEqual('true', master_params['metrics_server_enabled'])
        self.assertEqual('T0', master_params['timestamp_upgrade'])
        self.assertEqual('v1.30.0', master_params['kube_tag'])
        self.assertEqual('10', master_params['etcd_volume_size'])
        # Workers: only the changed worker-relevant param, no template push.
        self.assertEqual({'kubelet_options': '--max-pods=50'},
                         updates['worker-0']['parameters'])
        self.assertNotIn('template', updates['worker-0'])

    def test_reconfigure_cluster_leaves_unchanged_workers_alone(self):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('metrics_server_enabled', 'auto_healing_enabled'))
        osc = mock.MagicMock()
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={'auto_healing_enabled': 'False',
                        'reconciler_version': ''})
        worker = mock.MagicMock(role='worker', stack_id='cluster-stack',
                                is_default=True)
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        cluster = self._cluster(master, worker)
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['worker-0'])
        driver._get_update_timeout = mock.MagicMock(return_value=60)

        driver._reconfigure_workers(
            osc, cluster, {'metrics_server_enabled': 'true',
                           'auto_healing_enabled': 'false'})

        osc.heat.return_value.stacks.update.assert_not_called()

    def test_reconfigure_workers_pushes_only_node_switches_to_pools(self):
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('os_autoupgrade_enabled', 'kubelet_options'))
        osc = mock.MagicMock()
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={'os_autoupgrade_enabled': 'false',
                        'kubelet_options': '--pool-specific',
                        'reconciler_version': ''})
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        pool = mock.MagicMock(role='worker', stack_id='pool-stack',
                              is_default=False, labels={'kubelet_options':
                                                        '--pool-specific'})
        cluster = self._cluster(master, pool)
        cluster.labels = {'os_autoupgrade_enabled': 'true',
                          'kubelet_options': '--cluster'}
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['pool-0'])
        driver._get_update_timeout = mock.MagicMock(return_value=60)

        driver._reconfigure_workers(
            osc, cluster, {'os_autoupgrade_enabled': 'true',
                           'kubelet_options': '--cluster'})

        osc.heat.return_value.stacks.update.assert_called_once_with(
            'pool-0', existing=True,
            parameters={'os_autoupgrade_enabled': 'true'},
            timeout_mins=60, disable_rollback=True)
        self.assertEqual({'kubelet_options': '--pool-specific',
                          'os_autoupgrade_enabled': 'true'}, pool.labels)
        pool.save.assert_called_once_with()

    def test_reconfigure_workers_skips_legacy_members(self):
        # A pre-reconciler (Ussuri) worker runs bash fragments: a params
        # update would re-run them on a live node.
        driver = DummyKubernetesDriver()
        driver.definition.label_derived_params.return_value = frozenset(
            ('kubelet_options',))
        osc = mock.MagicMock()
        osc.heat.return_value.stacks.get.return_value = mock.MagicMock(
            parameters={'kubelet_options': ''})
        worker = mock.MagicMock(role='worker', stack_id='cluster-stack',
                                is_default=True)
        master = mock.MagicMock(role='master', stack_id='cluster-stack',
                                is_default=True)
        cluster = self._cluster(master, worker)
        driver._get_nested_stack_ids = mock.MagicMock(
            return_value=['worker-0'])

        driver._reconfigure_workers(osc, cluster,
                                    {'kubelet_options': '--max-pods=50'})

        osc.heat.return_value.stacks.update.assert_not_called()


class TestKubeFilesParam(base.TestCase):

    def test_packs_kube_file_labels(self):
        packed = k8s_tdef.kube_files_param({
            'kube_file_oidc_ca': '-----BEGIN CERTIFICATE-----\nAA==\n',
            'kube_file_audit': 'rules: []',
            'kubeapi_options': '--x'})
        files = json.loads(base64.b64decode(packed))
        self.assertEqual({'oidc_ca': '-----BEGIN CERTIFICATE-----\nAA==\n',
                          'audit': 'rules: []'}, files)

    def test_no_files_is_empty(self):
        self.assertEqual('', k8s_tdef.kube_files_param({'a': 'b'}))
        self.assertEqual('', k8s_tdef.kube_files_param(None))

    def test_rejects_unsafe_names(self):
        for bad in ('kube_file_', 'kube_file_a/b', 'kube_file_' + 'x' * 65):
            self.assertRaises(exception.InvalidParameterValue,
                              k8s_tdef.kube_files_param, {bad: 'x'})

    def test_rejects_oversized_payload(self):
        self.assertRaises(
            exception.InvalidParameterValue, k8s_tdef.kube_files_param,
            {'kube_file_big': 'x' * (k8s_tdef.KUBE_FILES_MAX_BYTES + 1)})


class TestHeatParamTypeForValue(base.TestCase):

    def test_infers_heat_type_from_value(self):
        # bool must win over int (bool is a subclass of int).
        self.assertEqual(
            'boolean', heat_driver._heat_param_type_for_value(True))
        self.assertEqual(
            'number', heat_driver._heat_param_type_for_value(5))
        self.assertEqual(
            'number', heat_driver._heat_param_type_for_value(1.5))
        self.assertEqual(
            'comma_delimited_list',
            heat_driver._heat_param_type_for_value(['a', 'b']))
        self.assertEqual(
            'json', heat_driver._heat_param_type_for_value({'k': 'v'}))
        self.assertEqual(
            'string', heat_driver._heat_param_type_for_value('v1.27.3'))
        self.assertEqual(
            'string', heat_driver._heat_param_type_for_value(''))


class TestDeprecatedParameterInjection(base.TestCase):
    """Cover the parameter-side half of rolling template migration.

    A new release that drops a parameter must still update an existing
    cluster whose retained ResourceGroup members reference it via
    ``{get_param: X}``; the parameter is re-declared in the new template so
    the reference resolves instead of failing ``Property X not assigned``.
    """

    def setUp(self):
        super(TestDeprecatedParameterInjection, self).setUp()
        self.driver = DummyKubernetesDriver()
        # A minimal "new" template that no longer declares flannel_cni_tag.
        self.new_template = {
            'parameters': {
                'kube_tag': {'type': 'string'},
                'number_of_minions': {'type': 'number'},
            },
            'resources': {},
        }
        # What the live (ussuri-created) stack still carries.  RAW form:
        # a hidden parameter (`password`) comes back masked from Heat.
        self.live_params = {
            'kube_tag': 'v1.27.3',
            'number_of_minions': '1',
            'flannel_cni_tag': 'v1.1.2',        # dropped + required downstream
            'prometheus_monitoring': True,
            'password': heat_tdef.MASKED_HEAT_PARAM_VALUE,   # hidden + dropped
            'OS::stack_id': 'abc',              # must be skipped
        }

    def test_injects_only_dropped_params(self):
        out = self.driver._inject_deprecated_parameters(
            self.new_template, self.live_params)
        params = out['parameters']
        # Re-declared because the new template dropped it.
        self.assertIn('flannel_cni_tag', params)
        self.assertEqual('string', params['flannel_cni_tag']['type'])
        self.assertEqual('v1.1.2', params['flannel_cni_tag']['default'])
        # Type inferred from the live value (bool -> boolean).
        self.assertEqual('boolean', params['prometheus_monitoring']['type'])
        # Already declared -> untouched (no clobber).
        self.assertEqual({'type': 'string'}, params['kube_tag'])
        # OS::* pseudo-parameters are never injected.
        self.assertNotIn('OS::stack_id', params)

    def test_masked_param_declared_without_value(self):
        # A masked (hidden) dropped param must be re-declared by NAME so its
        # get_param resolves, but its masked value must never become a default
        # (the real value is preserved by Heat's existing: True update).
        out = self.driver._inject_deprecated_parameters(
            self.new_template, self.live_params)
        self.assertIn('password', out['parameters'])
        self.assertEqual('string', out['parameters']['password']['type'])
        self.assertEqual('', out['parameters']['password']['default'])
        self.assertNotEqual(
            heat_tdef.MASKED_HEAT_PARAM_VALUE,
            out['parameters']['password']['default'])

    def test_injected_param_survives_filter(self):
        # End to end mirroring upgrade_cluster: inject sees RAW params, the
        # filter receives the masked-omitted set.  The re-declared non-masked
        # param keeps its value; the masked one is NOT passed (preserved by
        # existing: True), so it must not appear in the filtered values.
        augmented = self.driver._inject_deprecated_parameters(
            self.new_template, self.live_params)
        omitted = heat_tdef.omit_masked_heat_parameters(self.live_params)
        filtered = self.driver._filter_params_for_template(omitted, augmented)
        self.assertEqual('v1.1.2', filtered['flannel_cni_tag'])
        self.assertEqual(True, filtered['prometheus_monitoring'])
        self.assertNotIn('password', filtered)

    def test_noop_when_nothing_dropped(self):
        template = {'parameters': {'kube_tag': {'type': 'string'}}}
        out = self.driver._inject_deprecated_parameters(
            template, {'kube_tag': 'v1.27.3'})
        # Same object returned unchanged when there is nothing to inject.
        self.assertIs(template, out)

    def test_accepts_yaml_string_template(self):
        import yaml
        tmpl = yaml.safe_dump({'parameters': {'kube_tag': {'type': 'string'}}})
        out = self.driver._inject_deprecated_parameters(
            tmpl, {'kube_tag': 'v1', 'flannel_cni_tag': 'v1.1.2'})
        parsed = yaml.safe_load(out)
        self.assertIn('flannel_cni_tag', parsed['parameters'])
        self.assertEqual(
            'v1.1.2', parsed['parameters']['flannel_cni_tag']['default'])
