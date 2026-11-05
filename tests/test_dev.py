"""Pruebas del CLI de demostracion; no requieren Docker ni Mongo reales."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, call


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "dev.py"
spec = importlib.util.spec_from_file_location("extractext_demo", SCRIPT)
dev = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(dev)


class TestDemoCLI(unittest.TestCase):
    def test_compass_override_is_local_and_preserves_internal_network(self):
        self.assertIn("127.0.0.1:27017:27017", dev.COMPASS_OVERRIDE)
        self.assertIn("mongo_net_interna", dev.COMPASS_OVERRIDE)
        self.assertIn("mongo_compass_net", dev.COMPASS_OVERRIDE)
        self.assertNotIn("0.0.0.0:27017", dev.COMPASS_OVERRIDE)

    def test_start_creates_network_and_starts_compose(self):
        with patch.object(dev, "ensure_docker") as docker, \
             patch.object(dev, "ensure_configuration") as config, \
             patch.object(dev, "ensure_network") as network, \
             patch.object(dev, "compose") as compose:
            result = dev.main(["start", "--build"])
        self.assertEqual(result, 0)
        docker.assert_called_once()
        config.assert_called_once()
        network.assert_called_once()
        compose.assert_has_calls([call("config", "--quiet"), call("up", "-d", "--build"), call("ps")])

    def test_stop_never_deletes_volumes(self):
        with patch.object(dev, "ensure_docker"), patch.object(dev, "compose") as compose:
            self.assertEqual(dev.main(["stop", "--remove"]), 0)
        compose.assert_called_once_with("down")

    def test_compass_on_writes_generated_override_and_recreates_only_mongo(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mongo.yml"
            with patch.object(dev, "COMPASS_FILE", path), \
                 patch.object(dev, "ensure_docker"), \
                 patch.object(dev, "ensure_configuration"), \
                 patch.object(dev, "compose") as compose, \
                 patch.object(dev, "connection_available", return_value=True):
                self.assertEqual(dev.main(["compass-on"]), 0)
                self.assertEqual(path.read_text(encoding="utf-8"), dev.COMPASS_OVERRIDE)
        compose.assert_has_calls([
            call("config", "--quiet", compass=True),
            call("up", "-d", "--no-deps", "--force-recreate", "mongo", compass=True),
        ])

    def test_compass_on_never_overwrites_custom_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mongo.yml"
            path.write_text("custom", encoding="utf-8")
            with patch.object(dev, "COMPASS_FILE", path), \
                 patch.object(dev, "ensure_docker"), \
                 patch.object(dev, "ensure_configuration"), \
                 patch.object(dev, "compose") as compose:
                self.assertEqual(dev.main(["compass-on"]), 1)
                self.assertEqual(path.read_text(encoding="utf-8"), "custom")
                compose.assert_not_called()

    def test_compass_off_removes_only_generated_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mongo.yml"
            path.write_text(dev.COMPASS_OVERRIDE, encoding="utf-8")
            with patch.object(dev, "COMPASS_FILE", path), \
                 patch.object(dev, "ensure_docker"), \
                 patch.object(dev, "compose") as compose, \
                 patch.object(dev, "connection_available", return_value=False):
                self.assertEqual(dev.main(["compass-off"]), 0)
                self.assertFalse(path.exists())
        compose.assert_called_once_with("up", "-d", "--no-deps", "--force-recreate", "mongo")

    def test_upload_verifies_real_persistence_response(self):
        with tempfile.TemporaryDirectory() as directory:
            pdf = Path(directory) / "demo.pdf"
            pdf.write_bytes(b"%PDF-1.4\n%simple\n")
            response = [
                (200, {"id": "123", "checksum": "abc", "content": "texto", "summary_status": "queued"}),
                (200, {"id": "123", "checksum": "abc", "content": "texto"}),
            ]
            with patch.object(dev, "request_json", side_effect=response) as request:
                self.assertEqual(dev.main(["upload", "--pdf", str(pdf), "--unique"]), 0)
            self.assertEqual(request.call_count, 2)
            self.assertEqual(request.call_args_list[0].args[0:2], ("extraction", "/upload"))
            self.assertEqual(request.call_args_list[1].args[0:2], ("persistence", "/documents/123"))

    def test_upload_rejects_fake_success_when_checksum_differs(self):
        with tempfile.TemporaryDirectory() as directory:
            pdf = Path(directory) / "demo.pdf"
            pdf.write_bytes(b"%PDF-1.4")
            with patch.object(dev, "request_json", side_effect=[
                (200, {"id": "123", "checksum": "abc", "content": "texto"}),
                (200, {"id": "123", "checksum": "xyz", "content": "texto"}),
            ]):
                self.assertEqual(dev.main(["upload", "--pdf", str(pdf)]), 1)


class TestTraefikConsulACL(unittest.TestCase):
    def test_acl_token_is_in_the_actual_static_config(self):
        """Regression: TRAEFIK_* env is ignored if the static YAML exists."""
        root = SCRIPT.parents[1]
        template = (root / "traefik/config/traefik.yml").read_text(encoding="utf-8")
        compose = (root / "traefik/docker-compose.yml").read_text(encoding="utf-8")
        startup = (root / "traefik/start.sh").read_text(encoding="utf-8")
        self.assertIn('token: "__CONSUL_TRAEFIK_TOKEN__"', template)
        self.assertIn("CONSUL_TRAEFIK_TOKEN:", compose)
        self.assertNotIn("TRAEFIK_PROVIDERS_CONSULCATALOG_ENDPOINT_TOKEN:", compose)
        self.assertIn("traefik.template.yml", compose)
        self.assertIn("/etc/traefik/start.sh", compose)
        self.assertIn('exec traefik --configFile="$runtime"', startup)
        self.assertIn("umask 077", startup)
        self.assertIn("unset CONSUL_TRAEFIK_TOKEN", startup)


if __name__ == "__main__":
    unittest.main()
