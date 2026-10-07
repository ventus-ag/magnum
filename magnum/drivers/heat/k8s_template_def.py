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
import re

from oslo_config import cfg
from oslo_log import log as logging

from magnum.common import exception
from magnum.common import keystone
from magnum.common import neutron
from magnum.drivers.heat import template_def

CONF = cfg.CONF


LOG = logging.getLogger(__name__)


# Labels copied verbatim into the template parameter of the same name.
LABEL_PARAMS = ('flannel_network_cidr', 'flannel_backend',
                'admission_control_list',
                'grafana_admin_passwd',
                'kube_dashboard_enabled',
                'etcd_volume_size',
                'cert_manager_api',
                'kubelet_options',
                'kubeapi_options',
                'kubeproxy_options',
                'kubecontroller_options',
                'kubescheduler_options',
                'kube_scheduler_scoring_strategy',
                'cinder_csi_default_storage_class',
                'node_labels',
                'node_taints',
                'master_lb_allowed_cidrs')

# Rendered verbatim into component args/config on the nodes: an absent label
# must reach them as "" so removing it clears the setting.
CLEARABLE_LABEL_PARAMS = ('kubelet_options', 'kubeapi_options',
                          'kubeproxy_options', 'kubecontroller_options',
                          'kubescheduler_options',
                          'kube_scheduler_scoring_strategy',
                          'cinder_csi_default_storage_class')

# kube_file_<name>=<content> labels become /etc/kubernetes/files/<name> on
# every node (see kube_files_param).
KUBE_FILE_LABEL_PREFIX = 'kube_file_'
KUBE_FILES_MAX_BYTES = 64 * 1024
_KUBE_FILE_NAME = re.compile(r'^[A-Za-z0-9_-]{1,64}$')


def kube_files_param(labels):
    """Pack the kube_file_<name> labels into the kube_files parameter.

    Base64 of a sorted JSON object, so arbitrary multi-line content survives
    Heat and the shell-sourced heat-params file unchanged. "" when none.
    """
    files = {}
    for key, value in (labels or {}).items():
        if not key.startswith(KUBE_FILE_LABEL_PREFIX):
            continue
        name = key[len(KUBE_FILE_LABEL_PREFIX):]
        if not _KUBE_FILE_NAME.match(name):
            raise exception.InvalidParameterValue(
                'label %s: the file name after "%s" must match '
                '[A-Za-z0-9_-]{1,64}' % (key, KUBE_FILE_LABEL_PREFIX))
        files[name] = '' if value is None else str(value)
    if not files:
        return ''
    packed = json.dumps(files, sort_keys=True,
                        separators=(',', ':')).encode('utf-8')
    if len(packed) > KUBE_FILES_MAX_BYTES:
        raise exception.InvalidParameterValue(
            '%s* labels total %d bytes; the limit is %d' % (
                KUBE_FILE_LABEL_PREFIX, len(packed), KUBE_FILES_MAX_BYTES))
    return base64.b64encode(packed).decode('ascii')


"""kubernetes ports """
KUBE_SECURE_PORT = '6443'
KUBE_INSECURE_PORT = '8080'


class K8sApiAddressOutputMapping(template_def.OutputMapping):

    def set_output(self, stack, cluster_template, cluster):
        if self.cluster_attr is None:
            return

        output_value = self.get_output_value(stack)
        if output_value is not None:
            # TODO(yuanying): port number is hardcoded, this will be fix
            protocol = 'https'
            port = KUBE_SECURE_PORT
            if cluster_template.tls_disabled:
                protocol = 'http'
                port = KUBE_INSECURE_PORT

            params = {
                'protocol': protocol,
                'address': output_value,
                'port': port,
            }
            value = "%(protocol)s://%(address)s:%(port)s" % params
            setattr(cluster, self.cluster_attr, value)


class ServerAddressOutputMapping(template_def.NodeGroupOutputMapping):

    public_ip_output_key = None
    private_ip_output_key = None

    def __init__(self, dummy_arg, nodegroup_attr=None, nodegroup_uuid=None):
        self.nodegroup_attr = nodegroup_attr
        self.nodegroup_uuid = nodegroup_uuid
        self.heat_output = self.public_ip_output_key
        self.is_stack_param = False

    def set_output(self, stack, cluster_template, cluster):
        if not cluster.floating_ip_enabled:
            self.heat_output = self.private_ip_output_key

        LOG.debug("Using heat_output: %s", self.heat_output)
        super(ServerAddressOutputMapping,
              self).set_output(stack, cluster_template, cluster)


class MasterAddressOutputMapping(ServerAddressOutputMapping):
    public_ip_output_key = 'kube_masters'
    private_ip_output_key = 'kube_masters_private'


class NodeAddressOutputMapping(ServerAddressOutputMapping):
    public_ip_output_key = 'kube_minions'
    private_ip_output_key = 'kube_minions_private'


class K8sTemplateDefinition(template_def.BaseTemplateDefinition):
    """Base Kubernetes template."""

    label_params = LABEL_PARAMS

    def label_derived_params(self):
        """Template parameters whose value comes from cluster labels."""
        return frozenset(self.label_params) | {'kube_files'}

    def __init__(self):
        super(K8sTemplateDefinition, self).__init__()
        self.add_parameter('external_network',
                           cluster_template_attr='external_network_id',
                           required=True)
        self.add_parameter('fixed_network',
                           cluster_attr='fixed_network')
        self.add_parameter('fixed_subnet',
                           cluster_attr='fixed_subnet')
        self.add_parameter('network_driver',
                           cluster_template_attr='network_driver')
        self.add_parameter('volume_driver',
                           cluster_template_attr='volume_driver')
        self.add_parameter('tls_disabled',
                           cluster_template_attr='tls_disabled',
                           required=True)
        self.add_parameter('registry_enabled',
                           cluster_template_attr='registry_enabled')
        self.add_parameter('cluster_uuid',
                           cluster_attr='uuid',
                           param_type=str)
        self.add_parameter('insecure_registry_url',
                           cluster_template_attr='insecure_registry')
        self.add_parameter('kube_version',
                           cluster_attr='coe_version')

        self.add_output('api_address',
                        cluster_attr='api_address',
                        mapping_type=K8sApiAddressOutputMapping)
        self.add_output('kube_minions_private',
                        cluster_attr=None)
        self.add_output('kube_masters_private',
                        cluster_attr=None)
        self.default_subnet_cidr = '10.0.0.0/24'

    def get_nodegroup_param_maps(self, master_params=None, worker_params=None):
        master_params = master_params or dict()
        worker_params = worker_params or dict()
        master_params.update({
            'number_of_masters': 'node_count',
            'master_flavor': 'flavor_id',
            'master_image': 'image_id',
            'master_role': 'role',
            'master_nodegroup_name': 'name',
            'docker_volume_size': 'docker_volume_size'
        })
        worker_params.update({
            'number_of_minions': 'node_count',
            'minion_flavor': 'flavor_id',
            'minion_image': 'image_id',
            'worker_role': 'role',
            'worker_nodegroup_name': 'name',
            'docker_volume_size': 'docker_volume_size'
        })
        return super(
            K8sTemplateDefinition, self).get_nodegroup_param_maps(
                master_params=master_params, worker_params=worker_params)

    def update_outputs(self, stack, cluster_template, cluster,
                       nodegroups=None):
        nodegroups = nodegroups or [cluster.default_ng_worker,
                                    cluster.default_ng_master]
        for nodegroup in nodegroups:
            if nodegroup.role == 'master':
                self.add_output('kube_masters',
                                nodegroup_attr='node_addresses',
                                nodegroup_uuid=nodegroup.uuid,
                                mapping_type=MasterAddressOutputMapping)
                self.add_output(
                    'number_of_masters', nodegroup_attr='node_count',
                    nodegroup_uuid=nodegroup.uuid,
                    mapping_type=template_def.NodeGroupOutputMapping,
                    is_stack_param=True)
            else:
                self.add_output('kube_minions',
                                nodegroup_attr='node_addresses',
                                nodegroup_uuid=nodegroup.uuid,
                                mapping_type=NodeAddressOutputMapping)
                self.add_output(
                    'number_of_minions', nodegroup_attr='node_count',
                    nodegroup_uuid=nodegroup.uuid,
                    mapping_type=template_def.NodeGroupOutputMapping,
                    is_stack_param=True)
        super(K8sTemplateDefinition,
              self).update_outputs(stack, cluster_template, cluster,
                                   nodegroups=nodegroups)

    def get_net_params(self, context, cluster_template, cluster):
        extra_params = dict()
        # NOTE(lxkong): Convert external network name to UUID, the template
        # field name is confused. If external_network_id is not specified in
        # cluster template use 'public' as the default value, which is the same
        # with the heat template default value as before.
        external_network = cluster_template.external_network_id
        ext_net_id = neutron.get_external_network_id(context, external_network)
        extra_params['external_network'] = ext_net_id

        # NOTE(brtknr): Convert fixed network UUID to name if the given network
        # name is UUID like because OpenStack Cloud Controller Manager only
        # accepts a name as an argument to internal-network-name in the
        # cloud-config file provided to it. The default fixed network name is
        # the same as that defined in the heat template.
        fixed_network = cluster.fixed_network
        net_name = neutron.get_fixed_network_name(context, fixed_network)
        if net_name:
            extra_params['fixed_network_name'] = net_name
        else:
            extra_params['fixed_network_name'] = cluster.name

        if cluster.labels.get('fixed_subnet_cidr'):
            extra_params['fixed_subnet_cidr'] = cluster.labels.get(
                'fixed_subnet_cidr')

        # NOTE(brtknr): Convert fixed subnet name to UUID. If fixed_subnet
        # is not specified in cluster template use 'private' as the default
        # value, which is the same as the heat template default value.
        fixed_subnet = cluster.fixed_subnet
        subnet_id = neutron.get_fixed_subnet_id(context, fixed_subnet)
        if subnet_id:
            extra_params['fixed_subnet'] = subnet_id
            # NOTE(flwang): If a fixed subnet is given, then the label
            # fixed_subnet_cidr should be updated to reflect the correct
            # setting.
            extra_params['fixed_subnet_cidr'] = neutron.get_subnet(
                context, subnet_id, "id", "cidr")

        if cluster_template.no_proxy:
            extra_params["no_proxy"] = (
                cluster_template.no_proxy + "," + (
                    extra_params.get('fixed_subnet_cidr') or
                    self.default_subnet_cidr))

        return extra_params

    def get_params(self, context, cluster_template, cluster, **kwargs):
        extra_params = kwargs.pop('extra_params', {})

        extra_params['discovery_url'] = self.get_discovery_url(cluster)
        osc = self.get_osc(context)
        # NOTE: Sometimes, version discovery fails when Magnum cannot talk to
        # Keystone via specified magnum_client.endpoint_type intended for
        # cluster instances either because it is not unreachable from the
        # controller or CA certs are missing for TLS enabled interface and the
        # returned auth_url may not be suffixed with /v1 in which case append
        # the url with the suffix so that instances can still talk to Magnum.
        magnum_url = osc.magnum_url()
        extra_params['magnum_url'] = magnum_url + ('' if
                                                   magnum_url.endswith('/v1')
                                                   else '/v1')

        if cluster_template.tls_disabled:
            extra_params['loadbalancing_protocol'] = 'HTTP'
            extra_params['kubernetes_port'] = 8080

        extra_params['octavia_enabled'] = keystone.is_octavia_enabled()

        net_params = self.get_net_params(context, cluster_template, cluster)
        extra_params.update(net_params)

        labels = self._get_relevant_labels(cluster, kwargs)

        for label in LABEL_PARAMS:
            value = labels.get(label)
            if value is None and label in CLEARABLE_LABEL_PARAMS:
                value = ''
            extra_params[label] = value
        extra_params['kube_files'] = kube_files_param(labels)

        cluser_ip_range = cluster.labels.get('service_cluster_ip_range')
        if cluser_ip_range:
            extra_params['portal_network_cidr'] = cluser_ip_range

        if cluster_template.registry_enabled:
            extra_params['swift_region'] = CONF.docker_registry.swift_region
            extra_params['registry_container'] = (
                CONF.docker_registry.swift_registry_container)

        kube_tag = (labels.get("kube_tag") or
                    cluster_template.labels.get("kube_tag"))
        if kube_tag:
            extra_params['kube_version'] = kube_tag
            extra_params['master_kube_tag'] = kube_tag
            extra_params['minion_kube_tag'] = kube_tag

        self._set_master_lb_allowed_cidrs(context, cluster, extra_params)

        return super(K8sTemplateDefinition,
                     self).get_params(context, cluster_template, cluster,
                                      extra_params=extra_params,
                                      **kwargs)

    def _set_master_lb_allowed_cidrs(self, context, cluster, extra_params):
        if extra_params.get("master_lb_allowed_cidrs"):
            subnet_cidr = (cluster.labels.get("fixed_subnet_cidr") or
                           self.default_subnet_cidr)
            if extra_params.get("fixed_subnet"):
                subnet_cidr = neutron.get_subnet(context,
                                                 extra_params["fixed_subnet"],
                                                 "id", "cidr")
            extra_params["master_lb_allowed_cidrs"] += "," + subnet_cidr

    def get_scale_params(self, context, cluster, node_count,
                         scale_manager=None, nodes_to_remove=None, 
                         nodegroup=None):
        scale_params = dict()
        
        # Determine if we're scaling masters or workers
        is_master = (nodegroup and nodegroup.role == 'master')
        
        if is_master:
            # Master scaling parameters
            if nodes_to_remove:
                scale_params['masters_to_remove'] = nodes_to_remove
            if scale_manager:
                hosts = self.get_output('kube_masters_private')
                scale_params['masters_to_remove'] = (
                    scale_manager.get_removal_nodes(hosts))
            scale_params['number_of_masters'] = node_count
        else:
            # Worker scaling parameters (default/existing behavior)
            if nodes_to_remove:
                scale_params['minions_to_remove'] = nodes_to_remove
            if scale_manager:
                hosts = self.get_output('kube_minions_private')
                scale_params['minions_to_remove'] = (
                    scale_manager.get_removal_nodes(hosts))
            scale_params['number_of_minions'] = node_count
            
        return scale_params
