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

import json
import os
from unittest import mock

from magnum.drivers.heat import k8s_fedora_template_def as kftd
from magnum.drivers.k8s_fedora_coreos_v1 import template_def
from magnum.tests import base

USER_DATA = os.path.join(os.path.dirname(template_def.__file__),
                         'templates', 'user_data.json')


def render_ssh_key(value):
    with open(USER_DATA) as f:
        rendered = f.read().replace('__SSH_KEY_VALUE__', value)
    return json.loads(rendered)['passwd']['users'][0]['sshAuthorizedKeys'][0]


class TestFCOSSSHKeyParam(base.TestCase):

    def _get_params(self, base_params):
        tdef = template_def.FCOSK8sTemplateDefinition()
        with mock.patch.object(kftd.K8sFedoraTemplateDefinition,
                               'get_params', return_value=base_params), \
                mock.patch.object(template_def.utils, 'get_openstack_ca',
                                  return_value=''):
            return tdef.get_params(mock.Mock(), mock.Mock(), mock.Mock())

    def test_special_chars_render_valid_ignition(self):
        for key in (
            'ssh-ed25519 AAAAC3Nz CORP\\jdoe@LAPTOP01',
            'ssh-rsa AAAAB3Nz "quoted" comment',
            'ssh-rsa AAAAB3Nz tab\there',
        ):
            params = self._get_params({'ssh_public_key': key})
            self.assertEqual(key, render_ssh_key(params['ssh_public_key']))

    def test_ordinary_key_is_unchanged(self):
        for key in (
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA+mvUOB/x= user@host',
            'ssh-rsa AAAAB3Nz müller@pc',
        ):
            params = self._get_params({'ssh_public_key': key})
            self.assertEqual(key, params['ssh_public_key'])
            self.assertEqual(key, render_ssh_key(params['ssh_public_key']))

    def test_absent_key_stays_absent(self):
        self.assertNotIn('ssh_public_key', self._get_params({}))
        self.assertEqual(
            '', self._get_params({'ssh_public_key': ''})['ssh_public_key'])
