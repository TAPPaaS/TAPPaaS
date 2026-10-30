"""discover (ADR-040 D15): named fields only, a provider's flows by slug."""

from __future__ import annotations

import json
import unittest

from identity_controller import people_primitives as pp


class FakeManager:
    ROWS = {
        "/flows/instances/": [{"pk": "f1", "slug": "default-auth", "name": "Welcome", "designation": "authentication"}],
        "/providers/all/": [{
            "pk": 7, "name": "nextcloud", "verbose_name": "OAuth2/OpenID Provider",
            "assigned_application_slug": "nextcloud", "authorization_flow": "f1",
            "client_secret": "s3cret",
        }],
        "/outposts/instances/": [{"name": "embedded", "type": "proxy", "token_identifier": "t0k3n",
                                  "providers_obj": [{"name": "nextcloud"}]}],
    }

    def _get_json(self, path, **_params):
        return {"results": self.ROWS[path]}

    def _applications(self):
        return [{"slug": "nextcloud", "name": "Nextcloud", "provider_obj": {"name": "nextcloud"}}]


class DiscoverTests(unittest.TestCase):
    def test_shape(self):
        d = pp.discover(FakeManager())
        self.assertEqual(d["providers"][0]["flows"], {"authorization": "default-auth"})
        self.assertEqual(d["applications"][0]["provider"], "nextcloud")
        self.assertEqual(d["outposts"][0]["providers"], ["nextcloud"])

    def test_no_secret_leaves(self):
        text = json.dumps(pp.discover(FakeManager()))
        self.assertNotIn("s3cret", text)
        self.assertNotIn("t0k3n", text)


if __name__ == "__main__":
    unittest.main()
