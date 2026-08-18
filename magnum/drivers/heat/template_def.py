# Copyright 2016 Rackspace Inc. All rights reserved.
#
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
import abc
import ast
import json

from oslo_log import log as logging
from oslo_utils import strutils
from oslo_utils import uuidutils
import requests
import six

from magnum.common import clients
from magnum.common import exception
from magnum.common import keystone
from magnum.common import nova
from magnum.common import utils
from magnum.common.x509 import operations as x509
from magnum.i18n import _
import magnum.conf

from requests import exceptions as req_exceptions

LOG = logging.getLogger(__name__)

COMMON_TEMPLATES_PATH = "../../common/templates/"
COMMON_ENV_PATH = COMMON_TEMPLATES_PATH + "environments/"

CONF = magnum.conf.CONF
MASKED_HEAT_PARAM_VALUE = '******'


def is_masked_heat_parameter(value):
    return (isinstance(value, six.string_types) and
            value == MASKED_HEAT_PARAM_VALUE)


def get_unmasked_heat_parameter(parameters, key, default=None):
    value = parameters.get(key, default)
    if is_masked_heat_parameter(value):
        return default
    return value


def recover_service_account_params_from_db(stack_id):
    """Read a stack's stored service account keypair straight from heat's DB.

    ``kube_service_account_key`` and ``kube_service_account_private_key`` are
    declared ``hidden: true`` in the templates, so ``stacks.get()`` returns
    ``'******'`` for them -- the Heat API can never hand the real values back.
    The stored parameters live in ``raw_template.environment``, which is where
    this looks, falling back to the nested ``kube_masters`` stacks that carry
    the same values.

    Returns ``(public_key, private_key, ca_rotation_id)``; any element may be
    ``None``. Best-effort: without ``[cluster_heat] heat_db_connection`` (or on
    any failure) it returns ``(None, None, None)`` and the caller decides.
    """
    conn_url = CONF.cluster_heat.heat_db_connection
    if not conn_url or not stack_id:
        return None, None, None

    engine = None
    try:
        import sqlalchemy

        engine = sqlalchemy.create_engine(conn_url)
        with engine.connect() as conn:
            row = conn.execute(
                sqlalchemy.text(
                    "SELECT s.name, rt.environment FROM stack s "
                    "JOIN raw_template rt ON rt.id = s.raw_template_id "
                    "WHERE s.id = :sid AND s.deleted_at IS NULL"
                ),
                {"sid": stack_id},
            ).fetchone()
            if not row:
                return None, None, None

            stack_name, environment = row[0], row[1]
            found = _service_account_params_from_environment(environment)
            if found[0] and found[1]:
                return found

            # The root stack's copy can be missing on a tree whose parameters
            # were rewritten; every kube_masters member carries the same pair.
            # Only master stacks hold it, and a large tree (minion members,
            # software deployments) has far more than 50 nested stacks, so
            # scan kube_masters rows specifically.
            rows = conn.execute(
                sqlalchemy.text(
                    "SELECT rt.environment FROM stack s "
                    "JOIN raw_template rt ON rt.id = s.raw_template_id "
                    "WHERE s.name LIKE :prefix "
                    "AND s.name LIKE '%-kube_masters-%' "
                    "AND s.deleted_at IS NULL "
                    "LIMIT 50"
                ),
                {"prefix": stack_name + "-%"},
            ).fetchall()
            for nested in rows:
                found = _service_account_params_from_environment(nested[0])
                if found[0] and found[1]:
                    return found
    except Exception as exc:
        LOG.warning('Could not read the stored service account keypair of '
                    'stack %s from the heat DB: %s', stack_id, exc)
    finally:
        if engine is not None:
            engine.dispose()

    return None, None, None


def _service_account_params_from_environment(environment):
    """Pull the service account keypair out of a raw_template environment."""
    if not environment:
        return None, None, None
    try:
        if isinstance(environment, (bytes, bytearray)):
            environment = environment.decode('utf-8')
        if isinstance(environment, six.string_types):
            environment = json.loads(environment)
    except (ValueError, UnicodeDecodeError):
        return None, None, None
    if not isinstance(environment, dict):
        return None, None, None

    parameters = environment.get('parameters') or {}
    if not isinstance(parameters, dict):
        return None, None, None

    # With heat's encrypt_parameters_and_properties enabled the stored value is
    # ciphertext, not the key. Handing that back would install unusable SA
    # material on every master, which is worse than not recovering at all.
    encrypted = environment.get('encrypted_param_names') or []
    if not isinstance(encrypted, list):
        encrypted = []

    public = _usable_pem_parameter(
        parameters, 'kube_service_account_key', encrypted)
    private = _usable_pem_parameter(
        parameters, 'kube_service_account_private_key', encrypted)
    rotation_id = get_unmasked_heat_parameter(parameters, 'ca_rotation_id')
    return public, private, rotation_id


def _usable_pem_parameter(parameters, name, encrypted_param_names):
    """Return a stored parameter only if it is plainly a PEM document."""
    if name in encrypted_param_names:
        LOG.debug('Heat parameter %s is stored encrypted; cannot recover it '
                  'from the database.', name)
        return None
    value = get_unmasked_heat_parameter(parameters, name)
    if not value or not isinstance(value, six.string_types):
        return None
    if not value.lstrip().startswith('-----BEGIN'):
        LOG.debug('Heat parameter %s does not look like PEM material; '
                  'refusing to treat it as a recovered key.', name)
        return None
    return value


def set_service_account_params(heat_client, cluster, extra_params):
    """Resolve the cluster's service account keypair into ``extra_params``.

    The keypair signs and verifies every ServiceAccount token in the cluster.
    It is established at creation and must remain IDENTICAL on every master
    for the cluster's whole life: a master built with a different pair issues
    tokens the other apiservers reject with 401, and since client-go pins a
    long-lived connection to one backend, workloads then break permanently
    depending on which master they landed on.

    So a new pair is generated for a cluster CREATE only. For an existing
    cluster the stored pair is recovered -- from the Heat API when it is
    readable, otherwise straight from heat's DB, since the parameters are
    ``hidden`` and the API masks them. When the values are provably present but
    unreadable, they are omitted so an ``existing=True`` update preserves them
    (that is what makes a params-only resize safe without DB access). Only when
    the pair can neither be read nor safely preserved does this raise, because
    the alternative -- silently minting a replacement -- splits the control
    plane for the rest of the cluster's life.
    """
    if not cluster.stack_id:
        extra_params.setdefault('ca_rotation_id', '')
        _generate_service_account_params(extra_params)
        return

    reason = _('the stack could not be read')
    masked = False
    try:
        stack = heat_client.stacks.get(cluster.stack_id)
        stack_params = stack.parameters or {}
        extra_params['ca_rotation_id'] = stack_params.get('ca_rotation_id', '')

        public = get_unmasked_heat_parameter(
            stack_params, 'kube_service_account_key')
        private = get_unmasked_heat_parameter(
            stack_params, 'kube_service_account_private_key')
        if public and private:
            extra_params['kube_service_account_key'] = public
            extra_params['kube_service_account_private_key'] = private
            return

        masked = (
            is_masked_heat_parameter(
                stack_params.get('kube_service_account_key')) or
            is_masked_heat_parameter(
                stack_params.get('kube_service_account_private_key')))
        reason = (_('Heat masks them because they are declared hidden')
                  if masked
                  else _('the stack does not carry them'))
    except Exception as exc:
        reason = _('reading the stack failed: %s') % exc

    public, private, rotation_id = recover_service_account_params_from_db(
        cluster.stack_id)
    if public and private:
        LOG.debug('Recovered the stored service account keypair of cluster '
                  '%s from the heat DB.', cluster.uuid)
        extra_params['kube_service_account_key'] = public
        extra_params['kube_service_account_private_key'] = private
        if rotation_id is not None and not extra_params.get('ca_rotation_id'):
            extra_params['ca_rotation_id'] = rotation_id
        return

    if masked:
        # The stack demonstrably holds the real values; Heat is only hiding
        # them from us. Leaving the parameters unset makes an existing=True
        # update reuse them, which covers the params-only paths (resize).
        # A full-template update cannot preserve them this way, hence the
        # warning: configure heat_db_connection to close that gap.
        LOG.warning('Service account keys for cluster %s are masked in Heat '
                    'output and [cluster_heat] heat_db_connection is not '
                    'usable, so they can only be preserved implicitly. A '
                    'full-template update cannot carry them across and any '
                    'node it builds would get a fresh keypair, splitting '
                    'ServiceAccount token trust across the masters. Set '
                    'heat_db_connection to remove this risk.', cluster.uuid)
        return

    raise exception.ClusterServiceAccountKeysUnavailable(
        cluster_uuid=cluster.uuid, reason=reason)


def _generate_service_account_params(extra_params):
    csr_keys = x509.generate_csr_and_key(u"Kubernetes Service Account")
    extra_params['kube_service_account_key'] = (
        csr_keys["public_key"].replace("\n", "\\n"))
    extra_params['kube_service_account_private_key'] = (
        csr_keys["private_key"].replace("\n", "\\n"))


def omit_masked_heat_parameters(parameters):
    if not parameters:
        return {}
    return {
        key: value for key, value in parameters.items()
        if not is_masked_heat_parameter(value)
    }


class ParameterMapping(object):
    """A mapping associating heat param and cluster_template attr.

    A ParameterMapping is an association of a Heat parameter name with
    an attribute on a Cluster, ClusterTemplate, or both.

    In the case of both cluster_template_attr and cluster_attr being set, the
    ClusterTemplate will be checked first and then Cluster if the attribute
    isn't set on the ClusterTemplate.

    Parameters can also be set as 'required'. If a required parameter
    isn't set, a RequiredArgumentNotProvided exception will be raised.
    """
    def __init__(self, heat_param, cluster_template_attr=None,
                 cluster_attr=None, required=False, param_type=lambda x: x):
        self.heat_param = heat_param
        self.cluster_template_attr = cluster_template_attr
        self.cluster_attr = cluster_attr
        self.required = required
        self.param_type = param_type

    def set_param(self, params, cluster_template, cluster):
        value = self.get_value(cluster_template, cluster)
        if self.required and value is None:
            kwargs = dict(heat_param=self.heat_param)
            raise exception.RequiredParameterNotProvided(**kwargs)

        if value is not None:
            value = self.param_type(value)
            params[self.heat_param] = value

    def get_value(self, cluster_template, cluster):
        value = None
        if (self.cluster_template_attr and
                getattr(cluster_template, self.cluster_template_attr, None)
                is not None):
            value = getattr(cluster_template, self.cluster_template_attr)
        elif (self.cluster_attr and
                getattr(cluster, self.cluster_attr, None) is not None):
            value = getattr(cluster, self.cluster_attr)
        return value


class NodeGroupParameterMapping(ParameterMapping):

    def __init__(self, heat_param, nodegroup_attr=None, nodegroup_uuid=None,
                 required=False, param_type=lambda x: x):
        self.heat_param = heat_param
        self.nodegroup_attr = nodegroup_attr
        self.nodegroup_uuid = nodegroup_uuid
        self.required = required
        self.param_type = param_type

    def get_value(self, cluster_template, cluster):
        value = None
        for ng in cluster.nodegroups:
            if ng.uuid == self.nodegroup_uuid and self.nodegroup_attr in ng:
                value = getattr(ng, self.nodegroup_attr)
                break
        return value


class OutputMapping(object):
    """A mapping associating heat outputs and cluster attr.

    An OutputMapping is an association of a Heat output with a key
    Magnum understands.
    """

    def __init__(self, heat_output, cluster_attr=None):
        self.cluster_attr = cluster_attr
        self.heat_output = heat_output

    def set_output(self, stack, cluster_template, cluster):
        if self.cluster_attr is None:
            return

        output_value = self.get_output_value(stack)
        if output_value is None:
            return
        setattr(cluster, self.cluster_attr, output_value)

    def matched(self, output_key):
        return self.heat_output == output_key

    def get_output_value(self, stack):
        for output in stack.to_dict().get('outputs', []):
            if output['output_key'] == self.heat_output:
                return output['output_value']

        LOG.warning('stack does not have output_key %s', self.heat_output)
        return None


class NodeGroupOutputMapping(OutputMapping):
    """A mapping associating stack info and nodegroup attr.

    A NodeGroupOutputMapping is an association of a Heat output or parameter
    with a nodegroup field. By default stack output values are reflected to the
    specified nodegroup attribute. In the case where is_stack_param is set to
    True, the specified heat information will come from the stack parameters.
    """
    def __init__(self, heat_output, nodegroup_attr=None, nodegroup_uuid=None,
                 is_stack_param=False):
        self.nodegroup_attr = nodegroup_attr
        self.nodegroup_uuid = nodegroup_uuid
        self.heat_output = heat_output
        self.is_stack_param = is_stack_param

    def set_output(self, stack, cluster_template, cluster):
        if self.nodegroup_attr is None:
            return

        output_value = self.get_output_value(stack)
        if output_value is None:
            return

        for ng in cluster.nodegroups:
            if ng.uuid == self.nodegroup_uuid:
                # nodegroups are fetched from the database every
                # time, so the bad thing here is that we need to
                # save each change.
                previous_value = getattr(ng, self.nodegroup_attr, None)
                if previous_value == output_value:
                    # Avoid saving if it's not needed.
                    return
                setattr(ng, self.nodegroup_attr, output_value)
                ng.save()

    def get_output_value(self, stack):
        if not self.is_stack_param:
            return super(NodeGroupOutputMapping, self).get_output_value(stack)
        return self.get_param_value(stack)

    def get_param_value(self, stack):
        for param, value in stack.parameters.items():
            if param == self.heat_output:
                return value

        LOG.warning('stack does not have param %s', self.heat_output)
        return None


@six.add_metaclass(abc.ABCMeta)
class TemplateDefinition(object):
    """A mapping between Magnum objects and Heat templates.

    A TemplateDefinition is essentially a mapping between Magnum objects
    and Heat templates. Each TemplateDefinition has a mapping of Heat
    parameters.
    """

    def __init__(self):
        self.param_mappings = list()
        self.output_mappings = list()
        self.nodegroup_output_mappings = list()

    def add_parameter(self, *args, **kwargs):
        param_class = kwargs.pop('param_class', ParameterMapping)
        param = param_class(*args, **kwargs)
        self.param_mappings.append(param)

    def add_output(self, *args, **kwargs):
        mapping_type = kwargs.pop('mapping_type', OutputMapping)
        output = mapping_type(*args, **kwargs)
        if kwargs.get('cluster_attr', None):
            self.output_mappings.append(output)
        else:
            self.nodegroup_output_mappings.append(output)

    def get_output(self, *args, **kwargs):
        for output in self.output_mappings:
            if output.matched(*args, **kwargs):
                return output

        return None

    def get_params(self, context, cluster_template, cluster, **kwargs):
        """Pulls template parameters from ClusterTemplate.

        :param context: Context to pull template parameters for
        :param cluster_template: ClusterTemplate to pull template parameters
         from
        :param cluster: Cluster to pull template parameters from
        :param extra_params: Any extra params to be provided to the template

        :return: dict of template parameters
        """
        template_params = dict()

        for mapping in self.param_mappings:
            mapping.set_param(template_params, cluster_template, cluster)

        if 'extra_params' in kwargs:
            template_params.update(kwargs.get('extra_params'))

        return template_params

    def get_env_files(self, cluster_template, cluster, nodegroup=None):
        """Gets stack environment files based upon ClusterTemplate attributes.

        Base implementation returns no files (empty list). Meant to be
        overridden by subclasses.

        :param cluster_template: ClusterTemplate to grab environment files for

        :return: list of relative paths to environment files
        """
        return []

    def get_heat_param(self, cluster_attr=None, cluster_template_attr=None,
                       nodegroup_attr=None, nodegroup_uuid=None):
        """Returns stack param name.

        Return stack param name using cluster and cluster_template attributes
        :param cluster_attr: cluster attribute from which it maps to stack
         attribute
        :param cluster_template_attr: cluster_template attribute from which it
         maps to stack attribute

        :return: stack parameter name or None
        """
        for mapping in self.param_mappings:
            if hasattr(mapping, 'cluster_attr'):
                if mapping.cluster_attr == cluster_attr and \
                        mapping.cluster_template_attr == cluster_template_attr:
                    return mapping.heat_param
            if hasattr(mapping, 'nodegroup_attr'):
                if mapping.nodegroup_attr == nodegroup_attr and \
                        mapping.nodegroup_uuid == nodegroup_uuid:
                    return mapping.heat_param

        return None

    def get_stack_diff(self, context, heat_params, cluster):
        """Returns all the params that are changed.

        Compares the current params of a stack with the template def for
        the cluster and return the ones that changed.
        :param heat_params: a dict containing the current params and values
         for a stack
        :param cluster: the cluster we need to compare with.
        """
        diff = {}
        for mapping in self.param_mappings:
            try:
                heat_param_name = mapping.heat_param
                stack_value = heat_params[heat_param_name]
                value = mapping.get_value(cluster.cluster_template, cluster)
                if value is None:
                    continue
                # We need to avoid changing the param values if it's not
                # necessary, so for some attributes we need to resolve the
                # value either to name or uuid.
                value = self.resolve_ambiguous_values(context, heat_param_name,
                                                      stack_value, value)
                if stack_value != value:
                    diff.update({heat_param_name: value})
            except KeyError:
                # If the key is not in heat_params just skip it. In case
                # of update we don't want to trigger a rebuild....
                continue
        return diff

    def resolve_ambiguous_values(self, context, heat_param, heat_value, value):
        return str(value)

    def add_nodegroup_params(self, cluster, nodegroups=None):
        pass

    def update_outputs(self, stack, cluster_template, cluster,
                       nodegroups=None):
        for output in self.output_mappings:
            output.set_output(stack, cluster_template, cluster)
        for output in self.nodegroup_output_mappings:
            output.set_output(stack, cluster_template, cluster)

    @abc.abstractproperty
    def driver_module_path(self):
        pass

    @abc.abstractproperty
    def template_path(self):
        pass

    def extract_definition(self, context, cluster_template, cluster, **kwargs):
        nodegroups_list = kwargs.get('nodegroups', None)
        nodegroup = None if not nodegroups_list else nodegroups_list[0]
        return (self.template_path,
                self.get_params(context, cluster_template, cluster, **kwargs),
                self.get_env_files(cluster_template, cluster,
                                   nodegroup=nodegroup))


class BaseTemplateDefinition(TemplateDefinition):
    def __init__(self):
        super(BaseTemplateDefinition, self).__init__()
        self._osc = None

        self.add_parameter('ssh_key_name',
                           cluster_attr='keypair')
        self.add_parameter('dns_nameserver',
                           cluster_template_attr='dns_nameserver')
        self.add_parameter('http_proxy',
                           cluster_template_attr='http_proxy')
        self.add_parameter('https_proxy',
                           cluster_template_attr='https_proxy')
        self.add_parameter('no_proxy',
                           cluster_template_attr='no_proxy')

    @property
    def driver_module_path(self):
        pass

    @abc.abstractproperty
    def template_path(self):
        pass

    def get_osc(self, context):
        if not self._osc:
            self._osc = clients.OpenStackClients(context)
        return self._osc

    def get_params(self, context, cluster_template, cluster, **kwargs):
        osc = self.get_osc(context)

        nodegroups = kwargs.pop('nodegroups', None)
        # Add all the params from the cluster's nodegroups
        self.add_nodegroup_params(cluster, nodegroups=nodegroups)

        extra_params = kwargs.pop('extra_params', {})
        extra_params['trustee_domain_id'] = osc.keystone().trustee_domain_id
        extra_params['trustee_user_id'] = cluster.trustee_user_id
        extra_params['trustee_username'] = cluster.trustee_username
        extra_params['trustee_password'] = cluster.trustee_password
        extra_params['verify_ca'] = CONF.drivers.verify_ca
        extra_params['openstack_ca'] = utils.get_openstack_ca()
        ssh_public_key = nova.get_ssh_key(context, cluster.keypair)
        if ssh_public_key != "":
            extra_params['ssh_public_key'] = ssh_public_key

        # Only pass trust ID into the template if allowed by the config file
        if CONF.trust.cluster_user_trust:
            extra_params['trust_id'] = cluster.trust_id
        else:
            extra_params['trust_id'] = ""

        kwargs = {
            'service_type': 'identity',
            'interface': CONF.trust.trustee_keystone_interface,
            'version': 3
        }
        if CONF.trust.trustee_keystone_region_name:
            kwargs['region_name'] = CONF.trust.trustee_keystone_region_name
        # NOTE: Sometimes, version discovery fails when Magnum cannot talk to
        # Keystone via specified trustee_keystone_interface intended for
        # cluster instances either because it is not unreachable from the
        # controller or CA certs are missing for TLS enabled interface and the
        # returned auth_url may not be suffixed with /v3 in which case append
        # the url with the suffix so that instances can still talk to Keystone.
        auth_url = osc.url_for(**kwargs).rstrip('/')
        extra_params['auth_url'] = auth_url + ('' if auth_url.endswith('/v3')
                                               else '/v3')

        return super(BaseTemplateDefinition,
                     self).get_params(context, cluster_template, cluster,
                                      extra_params=extra_params,
                                      **kwargs)

    def resolve_ambiguous_values(self, context, heat_param, heat_value, value):
        # Ambiguous values should be converted to the same format.
        osc = self.get_osc(context)
        if heat_param == 'external_network':
            network = osc.neutron().show_network(heat_value).get('network')
            if uuidutils.is_uuid_like(heat_value):
                value = network.get('id')
            else:
                value = network('name')
        # Any other values we might need to resolve?
        return super(BaseTemplateDefinition, self).resolve_ambiguous_values(
            context, heat_param, heat_value, value)

    def add_nodegroup_params(self, cluster, nodegroups=None):
        master_params, worker_params = self.get_nodegroup_param_maps()
        nodegroups = nodegroups or [cluster.default_ng_worker,
                                    cluster.default_ng_master]
        for nodegroup in nodegroups:
            params = worker_params
            if nodegroup.role == 'master':
                params = master_params
            self._handle_nodegroup_param_map(nodegroup, params)

    def get_nodegroup_param_maps(self, master_params=None, worker_params=None):
        master_params = master_params or dict()
        worker_params = worker_params or dict()
        master_params.update({
            'number_of_masters': 'node_count',
        })
        return master_params, worker_params

    def _handle_nodegroup_param_map(self, nodegroup, param_map):
        for template_attr, nodegroup_attr in param_map.items():
            self.add_parameter(template_attr, nodegroup_attr=nodegroup_attr,
                               nodegroup_uuid=nodegroup.uuid,
                               param_class=NodeGroupParameterMapping)

    def _get_relevant_labels(self, cluster, kwargs):
        nodegroups = kwargs.get('nodegroups', None)
        labels = cluster.labels
        if nodegroups is not None:
            labels = nodegroups[0].labels
        return labels

    def update_outputs(self, stack, cluster_template, cluster,
                       nodegroups=None):
        master_ng = cluster.default_ng_master
        nodegroups = nodegroups or [cluster.default_ng_master]
        for nodegroup in nodegroups:
            if nodegroup.role == 'master':
                self.add_output('number_of_masters',
                                nodegroup_attr='node_count',
                                nodegroup_uuid=master_ng.uuid,
                                is_stack_param=True,
                                mapping_type=NodeGroupOutputMapping)
        super(BaseTemplateDefinition,
              self).update_outputs(stack, cluster_template, cluster,
                                   nodegroups=nodegroups)

    def validate_discovery_url(self, discovery_url, expect_size):
        url = str(discovery_url)
        if url[len(url)-1] == '/':
            url += '_config/size'
        else:
            url += '/_config/size'

        try:
            result = requests.get(url).text
        except req_exceptions.RequestException as err:
            LOG.error(err)
            raise exception.GetClusterSizeFailed(
                discovery_url=discovery_url)

        try:
            result = ast.literal_eval(result)
        except (ValueError, SyntaxError):
            raise exception.InvalidClusterDiscoveryURL(
                discovery_url=discovery_url)

        node_value = result.get('node', None)
        if node_value is None:
            raise exception.InvalidClusterDiscoveryURL(
                discovery_url=discovery_url)

        value = node_value.get('value', None)
        if value is None:
            raise exception.InvalidClusterDiscoveryURL(
                discovery_url=discovery_url)
        elif int(value) != expect_size:
            raise exception.InvalidClusterSize(
                expect_size=expect_size,
                size=int(value),
                discovery_url=discovery_url)

    def get_discovery_url(self, cluster):
        if hasattr(cluster, 'discovery_url') and cluster.discovery_url:
            # NOTE(flwang): The discovery URl does have a expiry time,
            # so better skip it when the cluster has been created.
            if not cluster.master_addresses:
                self.validate_discovery_url(cluster.discovery_url,
                                            cluster.master_count)
            discovery_url = cluster.discovery_url
        else:
            discovery_endpoint = (
                CONF.cluster.etcd_discovery_service_endpoint_format %
                {'size': cluster.master_count})
            try:
                discovery_request = requests.get(discovery_endpoint)
                if discovery_request.status_code != requests.codes.ok:
                    raise exception.GetDiscoveryUrlFailed(
                        discovery_endpoint=discovery_endpoint)
                discovery_url = discovery_request.text
            except req_exceptions.RequestException as err:
                LOG.error(err)
                raise exception.GetDiscoveryUrlFailed(
                    discovery_endpoint=discovery_endpoint)
            if not discovery_url:
                raise exception.InvalidDiscoveryURL(
                    discovery_url=discovery_url,
                    discovery_endpoint=discovery_endpoint)
            else:
                cluster.discovery_url = discovery_url
        return discovery_url

    def get_scale_params(self, context, cluster, node_count=None,
                         scale_manager=None, nodes_to_remove=None, 
                         nodegroup=None):
        return dict()


def add_lb_env_file(env_files, cluster):
    if cluster.master_lb_enabled:
        if keystone.is_octavia_enabled():
            env_files.append(COMMON_ENV_PATH + 'with_master_lb_octavia.yaml')
        else:
            env_files.append(COMMON_ENV_PATH + 'with_master_lb.yaml')
    else:
        env_files.append(COMMON_ENV_PATH + 'no_master_lb.yaml')


def add_volume_env_file(env_files, cluster, nodegroup=None):
    if nodegroup:
        docker_volume_size = nodegroup.docker_volume_size
    else:
        docker_volume_size = cluster.docker_volume_size
    if docker_volume_size is None:
        env_files.append(COMMON_ENV_PATH + 'no_volume.yaml')
    else:
        env_files.append(COMMON_ENV_PATH + 'with_volume.yaml')


def add_etcd_volume_env_file(env_files, cluster):
    if int(cluster.labels.get('etcd_volume_size', 0)) < 1:
        env_files.append(COMMON_ENV_PATH + 'no_etcd_volume.yaml')
    else:
        env_files.append(COMMON_ENV_PATH + 'with_etcd_volume.yaml')


def add_fip_env_file(env_files, cluster):
    lb_fip_enabled = cluster.labels.get("master_lb_floating_ip_enabled")
    master_lb_fip_enabled = (strutils.bool_from_string(lb_fip_enabled) or
                             cluster.floating_ip_enabled)

    if cluster.floating_ip_enabled:
        env_files.append(COMMON_ENV_PATH + 'enable_floating_ip.yaml')
    else:
        env_files.append(COMMON_ENV_PATH + 'disable_floating_ip.yaml')

    if cluster.master_lb_enabled and master_lb_fip_enabled:
        env_files.append(COMMON_ENV_PATH + 'enable_lb_floating_ip.yaml')
    else:
        env_files.append(COMMON_ENV_PATH + 'disable_lb_floating_ip.yaml')


def add_priv_net_env_file(env_files, cluster_template, cluster):
    if (cluster.fixed_network or cluster_template.fixed_network):
        env_files.append(COMMON_ENV_PATH + 'no_private_network.yaml')
    else:
        env_files.append(COMMON_ENV_PATH + 'with_private_network.yaml')
