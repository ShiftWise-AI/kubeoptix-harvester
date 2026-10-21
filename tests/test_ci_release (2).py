import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "ci_release", Path(__file__).resolve().parents[1] / "scripts/ci_release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_branch_matrix_rejects_forks(self):
        cases = [
            ("develop", "feature/change", True),
            ("develop", "fix/change", True),
            ("main", "develop", True),
            ("main", "fix/change", True),
            ("main", "feature/change", False),
            ("stage", "develop", False),
        ]
        for base, source, expected in cases:
            with self.subTest(base=base, source=source):
                pr = {
                    "base": {"ref": base, "repo": {"full_name": release.REPOSITORY}},
                    "head": {"ref": source, "repo": {"full_name": release.REPOSITORY}},
                }
                self.assertEqual(release.allowed_pr(pr), expected)
                pr["head"]["repo"]["full_name"] = "fork/harvester"
                self.assertFalse(release.allowed_pr(pr))

    def test_version_increments_latest_semver_tag(self):
        self.assertEqual(release.next_version(["1.0.3", "1.0.5", "1.0.4"]), "1.0.6")
        self.assertEqual(release.next_version([]), "1.0.1")
        with self.assertRaises(ValueError):
            release.next_version(["v1.0.5"])

    def test_only_harvester_operator_image_is_replaced(self):
        original = (
            "\t\tHarvesterImage:      registryImage(constants.HarvesterName),\n"
            "\t\tCoreAIImage:         registryImage(constants.CoreAIName),\n"
        )
        reference = release.IMAGE + ":1.0.6@sha256:" + "a" * 64
        updated = release.operator_image(original, reference)
        self.assertIn(f'HarvesterImage:      "{reference}",', updated)
        self.assertIn("CoreAIImage:         registryImage(constants.CoreAIName),", updated)
        with self.assertRaises(ValueError):
            release.operator_image("unexpected contract", reference)

    def test_workflow_requires_release_queue_and_secret_is_scoped(self):
        workflow = (Path(__file__).resolve().parents[1] /
                    ".github/workflows/ci-release.yml").read_text()
        self.assertIn("queue: max", workflow)
        self.assertIn("environment: quay-release", workflow)
        self.assertIn("needs: [ci-required]", workflow)
        self.assertIn("secrets.OPERATOR_TOKEN", workflow)
        self.assertNotIn("pull_request_target:", workflow)


if __name__ == "__main__":
    unittest.main()