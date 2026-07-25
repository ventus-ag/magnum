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

from keystoneauth1 import exceptions as ka_exception
from oslo_log import log as logging

from magnum.common import clients
from magnum.common import context as mag_ctx
from magnum.common import exception
from magnum.common import utils
import magnum.conf

CONF = magnum.conf.CONF
LOG = logging.getLogger(__name__)


def create_trustee_and_trust(osc, cluster):
    try:
        password = utils.generate_password(length=18)

        trustee = osc.keystone().create_trustee(
            "%s_%s" % (cluster.uuid, cluster.project_id),
            password,
        )

        cluster.trustee_username = trustee.name
        cluster.trustee_user_id = trustee.id
        cluster.trustee_password = password

        trust = osc.keystone().create_trust(
            cluster.trustee_user_id)
        cluster.trust_id = trust.id

    except Exception:
        LOG.exception(
            'Failed to create trustee and trust for Cluster: %s',
            cluster.uuid)
        raise exception.TrusteeOrTrustToClusterFailed(
            cluster_uuid=cluster.uuid)


def _admin_keystone():
    return clients.OpenStackClients(mag_ctx.make_admin_context()).keystone()


def _user_usable(admin_kst, user_id):
    """Whether a Keystone user still exists and is enabled.

    Returns ``(usable, detail)``.  A user that cannot be looked up at all is
    reported as usable so that a Keystone hiccup never triggers a needless
    trust rebuild -- only a definite NotFound / disabled answer does.
    """
    if not user_id:
        return False, 'no user id recorded'
    try:
        user = admin_kst.get_user(user_id)
    except ka_exception.NotFound:
        return False, 'user %s no longer exists' % user_id
    except Exception as e:
        LOG.warning('Could not look up user %s (%s); assuming it is fine',
                    user_id, e)
        return True, None
    if getattr(user, 'enabled', True) is False:
        return False, 'user %s is disabled' % user_id
    return True, None


def _recreate_trust(osc, context, cluster, reason='trust missing'):
    """Rebuild the cluster's trust with the upgrade caller as trustor.

    Used when the trust cannot be redeemed and cannot be repaired in place --
    the trust is gone, or its trustor user was deleted/disabled so there is no
    longer anyone to re-grant roles to.  The new ``trust_id`` is persisted
    before the Heat update so it propagates through heat-params into the node
    cloud.conf, and the in-cluster OCCM / CSI / auto-healer pick it up.

    Two things this does NOT inherit from the caller, both deliberate:

    * **Project.** ``create_trust`` scopes a trust to the caller's project, but
      this path normally runs as an operator scoped to the admin project while
      the cluster lives in a tenant project.  The trust's project is what the
      in-cluster cloud controllers provision into, so it is pinned to
      ``cluster.project_id``; inheriting the caller's would silently move the
      cluster's load balancers and volumes into the operator's project.
    * **Roles.** The caller is typically an admin, and delegating ``admin``
      would leave every healed cluster holding admin on its project forever.
      ``CONF.trust.recreate_roles`` (a minimal, sufficient set) is delegated
      instead, unless ``CONF.trust.roles`` pins an explicit list.

    The caller must hold those roles on the cluster's project for Keystone to
    let the trust be redeemed, so they are granted first when
    ``CONF.trust.heal_trustor_roles`` is on.  The result is then proven by
    redeeming a trust-scoped token: a trust that does not resolve to the
    cluster's project is discarded rather than written to the cluster row,
    because persisting a dead trust would overwrite the old one and destroy the
    evidence needed to repair it by hand.
    """
    old_trust_id = cluster.trust_id
    roles = CONF.trust.roles or CONF.trust.recreate_roles
    admin_kst = _admin_keystone()

    if CONF.trust.heal_trustor_roles:
        for role_id, role_name in admin_kst.find_role_ids(roles):
            try:
                admin_kst.grant_role(role_id, context.user_id,
                                     cluster.project_id)
            except Exception as e:
                LOG.warning(
                    'Cluster %s: could not grant role %s to the new trustor '
                    '%s on project %s: %s', cluster.uuid, role_name,
                    context.user_id, cluster.project_id, e)

    try:
        trust = osc.keystone().create_trust(
            cluster.trustee_user_id,
            project_id=cluster.project_id,
            roles=roles)
    except Exception:
        LOG.exception(
            'Failed to recreate trust for cluster %s (%s; trustee %s, new '
            'trustor %s, project %s, roles %s)',
            cluster.uuid, reason, cluster.trustee_user_id, context.user_id,
            cluster.project_id, roles)
        raise exception.TrusteeOrTrustToClusterFailed(
            cluster_uuid=cluster.uuid)

    # Prove it works before adopting it.
    try:
        proj, _user = osc.keystone().verify_trust_redeemable(
            cluster.trustee_user_id, cluster.trustee_password, trust.id)
    except Exception as e:
        LOG.error(
            'Cluster %s: rebuilt trust %s cannot be redeemed by trustee %s '
            '(%s). Keeping the old trust_id %s so the cluster can still be '
            'repaired by hand; the unusable trust is left in Keystone for '
            'inspection.',
            cluster.uuid, trust.id, cluster.trustee_user_id, e, old_trust_id)
        raise exception.TrusteeOrTrustToClusterFailed(
            cluster_uuid=cluster.uuid)
    if proj != cluster.project_id:
        LOG.error(
            'Cluster %s: rebuilt trust %s resolves to project %s, not the '
            'cluster project %s; refusing to adopt it (the cluster would '
            'provision load balancers and volumes into the wrong project).',
            cluster.uuid, trust.id, proj, cluster.project_id)
        raise exception.TrusteeOrTrustToClusterFailed(
            cluster_uuid=cluster.uuid)

    cluster.trust_id = trust.id
    # Record the new trustor so a later heal evaluates the identity that is
    # actually backing the trust, not the deleted user it replaced.
    cluster.user_id = context.user_id
    cluster.save()
    LOG.warning(
        'Rebuilt trust for cluster %s (%s): trustor is now %s, project %s, '
        'roles %s, trust_id %s -> %s (verified redeemable)',
        cluster.uuid, reason, context.user_id, cluster.project_id, roles,
        old_trust_id, trust.id)
    return True


def _heal_trustor_roles(cluster, trustor_user_id, project_id, roles):
    """Re-grant a trust's delegated roles to its trustor (idempotent).

    The common real-world breakage: the cluster creator (the trustor) was
    disabled and lost their project role assignments, then re-enabled. The
    trust still exists but cannot be redeemed, because Keystone requires the
    trustor to currently hold every delegated role -- so each trust-scoped
    token (conductor, Heat, OCCM, Cinder/Manila CSI, magnum-auto-healer) fails
    with 401/403. Re-granting exactly the delegated roles restores redemption.

    ``roles`` is a list of ``(role_id, role_name)`` tuples.
    """
    admin = clients.OpenStackClients(mag_ctx.make_admin_context()).keystone()
    granted = []
    for role_id, role_name in roles:
        if not role_id:
            continue
        try:
            admin.grant_role(role_id, trustor_user_id, project_id)
            granted.append(role_name or role_id)
        except Exception as e:
            LOG.warning(
                'Cluster %s: could not grant role %s to trustor %s on '
                'project %s: %s',
                cluster.uuid, role_name or role_id, trustor_user_id,
                project_id, e)
    if granted:
        LOG.warning(
            'Cluster %s: healed trust by granting trustor %s the delegated '
            'role(s) %s on project %s',
            cluster.uuid, trustor_user_id, granted, project_id)


def ensure_trust(osc, context, cluster):
    """Ensure the cluster's Keystone trust is usable before an upgrade.

    Two distinct failures are handled:

    1. **Trust role-stripped (common).** The trust still exists but its
       trustor (the cluster creator) no longer holds the delegated roles --
       e.g. the creator was disabled, which removes their project role
       assignments, then re-enabled. The trust cannot be redeemed, so the
       conductor's Heat update and the in-cluster cloud controllers all get
       401/403. Fixed by re-granting the trust's delegated roles to the
       trustor (gated by ``CONF.trust.heal_trustor_roles``).

    2. **Trust missing.** The trust is genuinely gone. Rebuilt with the
       upgrade caller as the new trustor.

    3. **Trustor user deleted or disabled (the hard-wedge case).** A Keystone
       trust dies with its trustor, and case 1's re-grant cannot help because
       there is nobody left to grant roles to -- every grant just fails and the
       upgrade proceeds still broken. Detected up front by looking the trustor
       up as admin, and repaired by the same rebuild as case 2 (gated by
       ``CONF.trust.heal_dead_trustor``). This is what a federated OIDC creator
       being reprovisioned leaves behind: delete still works because it falls
       back to the admin context, but upgrade and resize do not.

    The **trustee** (the cluster's own service account) is checked first. If it
    is gone there is nothing to delegate to and no rebuild is possible, so the
    cluster is reported for manual repair rather than silently left alone.

    The trust is read **as the trustee** -- the upgrade caller is not a party
    to the trust, and a project-scoped admin token cannot read another user's
    trust (Keystone policy needs system scope), so only the trustee read is
    reliable. An unscoped trustee token is used because a trust-scoped token is
    exactly what is unobtainable when the trustor lost its roles.

    :param osc: OpenStackClients built from the request ``context``
    :param context: request context of the operator triggering the operation
    :param cluster: the cluster whose trust to ensure
    :returns: True if the trust was recreated, False otherwise
    """
    # Liberty-era clusters never had a trust; nothing to ensure.
    if not cluster.trustee_user_id:
        return False

    admin_kst = _admin_keystone()

    # The trustee is the identity every rebuild delegates TO. If it is gone,
    # no repair here is possible -- say so loudly instead of failing later
    # with an opaque 401 from the conductor and from every in-cluster
    # controller.
    trustee_ok, trustee_detail = _user_usable(admin_kst,
                                              cluster.trustee_user_id)
    if not trustee_ok:
        LOG.error(
            'Cluster %s: its trustee (service account) is unusable -- %s. The '
            'trust cannot be repaired automatically; the cluster needs a new '
            'trustee created and grafted onto its row before upgrade or '
            'resize will work.',
            cluster.uuid, trustee_detail)
        return False

    # No trust recorded at all -> create one.
    if not cluster.trust_id:
        return _recreate_trust(osc, context, cluster,
                               reason='no trust recorded')

    # A trust dies with its trustor, so a deleted/disabled trustor is
    # terminal for the existing trust no matter what the trust row says.
    # Check before reading the trust: the read can succeed and lead to a
    # role re-grant against a user that no longer exists, which fails every
    # grant and leaves the cluster just as broken.
    trustor_ok, trustor_detail = _user_usable(admin_kst, cluster.user_id)
    if not trustor_ok:
        if not CONF.trust.heal_dead_trustor:
            LOG.error(
                'Cluster %s: trustor unusable (%s) so its trust cannot be '
                'redeemed, and [trust] heal_dead_trustor is off. Upgrade and '
                'resize will fail 401/403 until the trust is rebuilt by hand.',
                cluster.uuid, trustor_detail)
            return False
        LOG.warning(
            'Cluster %s: trustor unusable (%s); rebuilding its trust with the '
            'upgrade caller %s as trustor',
            cluster.uuid, trustor_detail, context.user_id)
        return _recreate_trust(osc, context, cluster,
                               reason='trustor %s' % trustor_detail)

    try:
        trust = osc.keystone().get_trust_as_trustee(
            cluster.trustee_user_id, cluster.trustee_password,
            cluster.trust_id)
    except ka_exception.NotFound:
        LOG.warning('Cluster %s trust %s no longer exists; recreating',
                    cluster.uuid, cluster.trust_id)
        return _recreate_trust(osc, context, cluster)
    except Exception as e:
        # Could not verify the trust (e.g. trustee auth failed). Leave it
        # untouched rather than risk a needless recreate or wrong re-grant.
        LOG.warning(
            'Cluster %s: could not read trust %s as trustee (%s); skipping '
            'trust heal', cluster.uuid, cluster.trust_id, e)
        return False

    # Trust is alive -- re-grant its delegated roles to the trustor so it can
    # be redeemed even if the trustor was role-stripped.
    if CONF.trust.heal_trustor_roles:
        roles = [(r.get('id'), r.get('name')) for r in (trust.roles or [])]
        _heal_trustor_roles(cluster, trust.trustor_user_id,
                            getattr(trust, 'project_id', cluster.project_id),
                            roles)
    return False


def delete_trustee_and_trust(osc, context, cluster):
    try:
        kst = osc.keystone()

        # The cluster which is upgraded from Liberty doesn't have trust_id
        if cluster.trust_id:
            kst.delete_trust(context, cluster)
    except Exception:
        # Exceptions are already logged by keystone().delete_trust
        pass
    try:
        # The cluster which is upgraded from Liberty doesn't have
        # trustee_user_id
        if cluster.trustee_user_id:
            osc.keystone().delete_trustee(cluster.trustee_user_id)
    except Exception:
        # Exceptions are already logged by keystone().delete_trustee
        pass
