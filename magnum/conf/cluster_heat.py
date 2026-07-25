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

cluster_heat_group = cfg.OptGroup(name='cluster_heat',
                                  title='Heat options for Cluster '
                                        'configuration')

cluster_heat_opts = [
    cfg.IntOpt('max_attempts',
               default=2000,
               help=('Number of attempts to query the Heat stack for '
                     'finding out the status of the created stack and '
                     'getting template outputs.  This value is ignored '
                     'during cluster creation if timeout is set as the poll '
                     'will continue until cluster creation either ends '
                     'or times out.'),
               deprecated_group='bay_heat'),
    cfg.IntOpt('wait_interval',
               default=1,
               help=('Sleep time interval between two attempts of querying '
                     'the Heat stack.  This interval is in seconds.'),
               deprecated_group='bay_heat'),
    cfg.IntOpt('create_timeout',
               default=60,
               help=('The length of time to let cluster creation continue. '
                     'This interval is in minutes. The default is 60 minutes.'
                     ),
               deprecated_group='bay_heat',
               deprecated_name='bay_create_timeout'),
    cfg.IntOpt('update_timeout',
               default=90,
               help=('The length of time to let cluster update operations '
                     'such as upgrade and CA rotation continue. This '
                     'interval is in minutes. The default is 90 minutes. '
                     'CA rotation runs a multi-phase prepare/cutover/finalize '
                     'protocol coordinated across all nodes, so this must '
                     'comfortably exceed the time for the slowest node to '
                     'complete all phases (control-plane restarts plus '
                     'cluster-wide barriers).')),
    cfg.IntOpt('update_timeout_per_node',
               default=30,
               help=('Extra Heat stack-update budget, in minutes, granted per '
                     'node beyond the first during upgrade, reconfigure and CA '
                     'rotation. Batch-1 rolling updates converge nodes '
                     'serially, so the whole-stack timeout must cover the '
                     'slowest serial chain rather than a single node. The '
                     'effective timeout is update_timeout + '
                     'update_timeout_per_node * (master_count + node_count - '
                     '1). It is a ceiling, not a wait: healthy updates still '
                     'finish early. Set to 0 to restore the flat '
                     'update_timeout behaviour. Raise it for slow first '
                     'old->new migrations or low-RAM nodes where a single '
                     'node reconcile can take 20-30 minutes.')),
    cfg.StrOpt('heat_db_connection',
               default='',
               secret=True,
               help=('Optional SQLAlchemy connection URL for the HEAT '
                     'database (e.g. mysql+pymysql://heat:pass@host/heat). '
                     'When set, Magnum runs pre-update repairs on a '
                     'cluster\'s stack tree before pushing a stack update: '
                     'backfills NULL resource.updated_at rows '
                     '(updated_at = created_at), and repairs the tenant of '
                     'software_config/software_deployment rows minted '
                     'outside the cluster\'s project by a past admin-context '
                     'operation (those rows are tenant-filtered out of reads '
                     'and fail updates with "Software config with id X not '
                     'found"). Such rows are '
                     'minted whenever Heat replaces a resource that is then '
                     'never updated (e.g. a SoftwareDeployment replaced '
                     'after a failed run), and a later update that compares '
                     'or sorts on the timestamp aborts with "\'<\' not '
                     'supported between instances of \'datetime.datetime\' '
                     'and \'NoneType\'", wedging upgrade and resize until an '
                     'operator runs the backfill SQL by hand. The Heat API '
                     'exposes no way to read or set the raw updated_at '
                     '(resource listings fall back to created_at), so a '
                     'direct DB write is the only automated remedy that does '
                     'not modify Heat itself. Leave empty to disable; the '
                     'manual runbook SQL then remains necessary on affected '
                     'clusters.')),
    cfg.IntOpt('stale_lock_grace_minutes',
               default=0,
               help=('Extra, opt-in half of the stale convergence-lock repair: '
                     'also clear resource.engine_id when stacks in the tree '
                     'still claim to be IN_PROGRESS, once the whole tree has '
                     'had NO database activity for this many minutes. '
                     'Requires heat_db_connection. 0 (the default) leaves '
                     'IN_PROGRESS trees alone. '
                     'NOTE the safe half needs no option and is always on '
                     'when heat_db_connection is set: when no stack in the '
                     'tree is IN_PROGRESS, any surviving engine_id is '
                     'provably stale, because convergence only stamps it '
                     'during a traversal and a traversal keeps its stack '
                     'IN_PROGRESS. '
                     'A traversal cancelled by re-triggering an update while '
                     'the stack is still IN_PROGRESS can leave engine_id set; '
                     'every later update then fails "<resource> is locked or '
                     'does not exist", cancels, and re-strands the same rows '
                     '-- a self-perpetuating wedge with no Heat API remedy, '
                     'because no API clears that column. '
                     'CAUTION when enabling: under convergence (the default '
                     'since Newton) Heat does NOT take stack_lock rows, so '
                     'their absence proves nothing about liveness -- quiet '
                     'time is the only signal available from the DB. A node '
                     'whose SoftwareDeployment is legitimately still running '
                     'writes nothing to the DB while it waits, so this value '
                     'MUST exceed the longest plausible single-node reconcile '
                     '(a first old->new migration can take 30 minutes; 90 or '
                     'more is a safe starting point). Set too low, this will '
                     'clear locks out from under a live traversal and corrupt '
                     'an in-flight create or update.'))
]


def register_opts(conf):
    conf.register_group(cluster_heat_group)
    conf.register_opts(cluster_heat_opts, group=cluster_heat_group)


def list_opts():
    return {
        cluster_heat_group: cluster_heat_opts
    }
