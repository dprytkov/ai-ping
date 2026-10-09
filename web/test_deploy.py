"""Offline checks for deployment parameters and Nginx include insertion."""
import contextlib
import io
import unittest

import deploy


class DeploymentTests(unittest.TestCase):
    def test_host_and_absolute_vhost_are_required_and_validated(self):
        host, path = deploy.deployment_options(['--host', 'panel.example.com', '--vhost', '/etc/nginx/panel.conf'])
        self.assertEqual(host, 'panel.example.com')
        self.assertTrue(path.is_absolute())
        invalid = [[], ['--host', 'panel.example.com'],
                   ['--host', 'panel.example.com', '--vhost', 'relative.conf']]
        for host in ('https://panel.example.com', 'panel.example.com/path', 'panel.example.com:443',
                     'panel;id', 'panel\nexample', '-panel.example.com', 'panel..example.com'):
            invalid.append(['--host', host, '--vhost', '/etc/nginx/panel.conf'])
        for arguments in invalid:
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                deploy.deployment_options(arguments)

    def test_include_is_idempotent_and_preserves_other_vhosts(self):
        source = 'server {\n  server_name other.example.com;\n}\nserver {\n\tserver_name panel.example.com;\n}\n'
        updated = deploy.include_panel(source, 'panel.example.com')
        self.assertIn('server_name other.example.com;\n}', updated)
        self.assertIn('server_name panel.example.com;\n    include /etc/nginx/snippets/ai-ping-web.conf;', updated)
        self.assertEqual(deploy.include_panel(updated, 'panel.example.com'), updated)

    def test_wrong_or_ambiguous_vhost_is_rejected(self):
        for source in ('server_name other.example.com;\n',
                       'server_name panel.example.com;\nserver_name panel.example.com;\n'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                deploy.include_panel(source, 'panel.example.com')


if __name__ == '__main__':
    unittest.main()
