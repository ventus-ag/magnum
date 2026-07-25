# Licensed under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License. You may obtain a copy
# of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from oslo_config import cfg

from magnum.i18n import _

trust_group = cfg.OptGroup(name='trust',
                           title='Trustee options for the magnum services')

trust_opts = [
    cfg.BoolOpt('cluster_user_trust',
                default=False,
                help=_('This setting controls whether to assign a trust to'
                       ' the cluster user or not. You will need to set it to'
                       ' True for clusters with volume_driver=cinder or'
                       ' registry_enabled=true in the underlying cluster'
                       ' template to work. This is a potential security risk'
                       ' since the trust gives instances OpenStack API access'
                       " to the cluster's project. Note that this setting"
                       ' does not affect per-cluster trusts assigned to the'
                       ' Magnum service user.')),
    cfg.StrOpt('trustee_domain_id',
               help=_('Id of the domain to create trustee for clusters')),
    cfg.StrOpt('trustee_domain_name',
               help=_('Name of the domain to create trustee for s')),
    cfg.StrOpt('trustee_domain_admin_id',
               help=_('Id of the admin with roles sufficient to manage users'
                      ' in the trustee_domain')),
    cfg.StrOpt('trustee_domain_admin_name',
               help=_('Name of the admin with roles sufficient to manage users'
                      ' in the trustee_domain')),
    cfg.StrOpt('trustee_domain_admin_domain_id',
               help=_('Id of the domain admin user\'s domain.'
                      ' trustee_domain_id is used by default')),
    cfg.StrOpt('trustee_domain_admin_domain_name',
               help=_('Name of the domain admin user\'s domain.'
                      ' trustee_domain_name is used by default')),
    cfg.StrOpt('trustee_domain_admin_password', secret=True,
               help=_('Password of trustee_domain_admin')),
    cfg.ListOpt('roles',
                default=[],
                help=_('The roles which are delegated to the trustee '
                       'by the trustor')),
    cfg.StrOpt('trustee_keystone_interface',
               default='public',
               help=_('Auth interface used by instances/trustee')),
    cfg.StrOpt('trustee_keystone_region_name',
               help=_('Region in Identity service catalog to use for '
                      'communication with the OpenStack service.')),
    cfg.BoolOpt('heal_trustor_roles',
                default=True,
                help=_('On cluster upgrade, if the cluster trust still exists '
                       'but its trustor no longer holds the delegated roles on '
                       'the cluster project, re-grant those roles so the trust '
                       'can be redeemed again. This heals clusters whose '
                       'creator was disabled and lost their role assignments '
                       '(every trust-scoped token -- conductor, Heat, OCCM, '
                       'CSI, auto-healer -- otherwise fails with 401/403). '
                       'Requires magnum to have rights to grant roles on the '
                       'project. Set to False to disable the automatic '
                       're-grant.')),
    cfg.IntOpt('heal_timeout',
               default=30,
               help=_('Hard upper bound, in seconds, on the pre-upgrade trust '
                      'heal. The heal makes synchronous Keystone calls; if any '
                      'stalls it must never block the upgrade, so the whole '
                      'heal is wrapped in a timeout and the upgrade proceeds '
                      'regardless. Also used as the per-request timeout for the '
                      'trustee read. Set to 0 to disable the heal entirely.')),
    cfg.BoolOpt('heal_dead_trustor',
                default=True,
                help=_('On cluster upgrade, if the cluster trust cannot be '
                       'redeemed because its trustor user was DELETED (or '
                       'disabled) -- the common outcome when the creator was a '
                       'federated OIDC user that got reprovisioned -- rebuild '
                       'the trust with the operator running the upgrade as the '
                       'new trustor. Without this the cluster is hard-wedged: '
                       'upgrade and resize both fail 401/403 and the existing '
                       'role re-grant cannot help, because there is no longer '
                       'a trustor to grant roles to. The rebuilt trust is '
                       'always scoped to the CLUSTER\'s project, never the '
                       'operator\'s, and is verified by redeeming a '
                       'trust-scoped token before it is persisted. Set to '
                       'False to leave such clusters for manual repair.')),
    cfg.ListOpt('recreate_roles',
                default=['_member_', 'load-balancer_admin'],
                help=_('Roles delegated when a trust is rebuilt after its '
                       'trustor was deleted. Deliberately NOT the caller\'s '
                       'roles: that path runs as an operator who typically '
                       'holds "admin", and inheriting it would hand every '
                       'healed cluster admin rights on its project for the '
                       'rest of its life. This is the minimal set proven '
                       'sufficient for the in-cluster cloud controllers '
                       '(OCCM load balancers, Cinder/Manila CSI volumes, '
                       'auto-healer). Overridden by the "roles" option when '
                       'that is set.'))
]


def register_opts(conf):
    conf.register_group(trust_group)
    conf.register_opts(trust_opts, group=trust_group)


def list_opts():
    return {
        trust_group: trust_opts
    }
