import argparse
import json
import os
from pathlib import Path
import re
import subprocess


REPOSITORY = "ShiftWise-AI/kubeoptix-harvester"
OPERATOR = "ShiftWise-AI/kubeoptix-operator"
IMAGE = "quay.io/parraes/kubeoptix-harvester"
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def run_operator_release_probe(root):
    subprocess.run(
        ["go", "test", "-run", "^TestCIHarvesterReleaseImage$", "./internal/operands"],
        cwd=root,
        check=True,
    )


def api(path, method="GET", payload=None):
    command = ["gh", "api", path, "--method", method]
    if payload is not None:
        command += ["--input", "-"]
    return json.loads(subprocess.check_output(
        command, input=None if payload is None else json.dumps(payload), text=True
    ))


def allowed_pr(pr):
    base = pr.get("base", {})
    head = pr.get("head", {})
    if (base.get("repo") or {}).get("full_name") != REPOSITORY:
        return False
    if (head.get("repo") or {}).get("full_name") != REPOSITORY:
        return False
    source = head.get("ref", "")
    if base.get("ref") == "develop":
        return bool(re.fullmatch(r"(?:feature|fix)/[^\s]+", source))
    if base.get("ref") == "main":
        return source == "develop" or bool(re.fullmatch(r"fix/[^\s]+", source))
    return False


def version_tuple(value):
    if not SEMVER.fullmatch(value):
        raise ValueError(f"Invalid MAJOR.MINOR.PATCH: {value}")
    return tuple(map(int, value.split(".")))


def next_version(released):
    versions = [version_tuple(value) for value in released]
    if not versions:
        return "1.0.1"
    major, minor, patch = max(versions)
    return f"{major}.{minor}.{patch + 1}"


def verify_source(source):
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Expected full source commit SHA")
    run("git", "merge-base", "--is-ancestor", source, "origin/main")
    prs = api(f"repos/{REPOSITORY}/commits/{source}/pulls?per_page=100")
    if not any(pr.get("merged_at") and pr.get("merge_commit_sha") == source
               and pr["base"]["ref"] == "main" and allowed_pr(pr) for pr in prs):
        raise ValueError("Release source must be the merge commit of an allowed same-repository PR to main")


def output(**values):
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def reserve(source):
    verify_source(source)
    tags = run("git", "tag", "--list", "v*").splitlines()
    releases = [tag[1:] for tag in tags if SEMVER.fullmatch(tag[1:])]
    marker = f"Release-Source: {source}"
    matches = [tag for tag in tags if SEMVER.fullmatch(tag[1:]) and
               marker in run("git", "for-each-ref", "--format=%(contents)", f"refs/tags/{tag}").splitlines()]
    if len(matches) > 1:
        raise ValueError("Multiple releases reserved for the same source")
    if matches:
        tag = matches[0]
        if run("git", "rev-parse", f"{tag}^{{commit}}") != source:
            raise ValueError("Reserved release has an unexpected source commit")
    else:
        version = next_version(releases)
        tag = f"v{version}"
        if tag in tags:
            raise ValueError(f"Version {tag} is already reserved for another source")
        run("git", "tag", "-a", tag, source, "-m", marker)
        run("git", "push", "origin", f"refs/tags/{tag}")
    run("git", "checkout", "--detach", source)
    output(version=tag[1:], tag=tag, source=source)


def operator_image(text, reference):
    updated, count = re.subn(
        r'(?m)^(\s*HarvesterImage:\s+)(?:registryImage\(constants.HarvesterName\)|"[^"\n]+"),$',
        lambda match: f'{match[1]}"{reference}",', text,
    )
    if count != 1:
        raise ValueError("Operator HarvesterImage contract changed; refusing broad edits")
    return updated


def update_operator(version, digest, directory="operator"):
    version_tuple(version)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("Invalid registry digest")
    reference = f"{IMAGE}:{version}@{digest}"
    root = Path(directory).resolve()
    branch = f"fix/harvester-{version}"
    remote_branches = run("git", "ls-remote", "--heads", "origin", branch, cwd=root)
    if remote_branches:
        run("git", "fetch", "origin", branch, cwd=root)
        run("git", "checkout", "--detach", "FETCH_HEAD", cwd=root)
    path = root / "internal/operands/settings.go"
    before = path.read_text()
    after = operator_image(before, reference)
    if after != before:
        path.write_text(after)
        run("gofmt", "-w", str(path))
    probe = root / "internal/operands/ci_harvester_release_test.go"
    if probe.exists():
        raise ValueError("Refusing to overwrite an existing Operator test")
    probe.write_text(
        'package operands\nimport "testing"\n'
        'func TestCIHarvesterReleaseImage(t *testing.T) {\n'
        f'if got := FromCR(newShiftWise()).HarvesterImage; got != "{reference}" {{\n'
        't.Fatalf("unexpected Harvester image: %s", got)\n}\n}\n'
    )
    try:
        run_operator_release_probe(root)
    finally:
        probe.unlink()
    changed = run("git", "diff", "--name-only", cwd=root).splitlines()
    if changed not in ([], ["internal/operands/settings.go"]):
        raise ValueError("Unexpected Operator changes")
    if changed:
        run("git", "checkout", "-B", branch, cwd=root)
        run("git", "add", "internal/operands/settings.go", cwd=root)
        run("git", "commit", "-m", f"fix: pin Harvester to {version}", cwd=root)
        run("git", "push", "origin", f"HEAD:refs/heads/{branch}", cwd=root)
    elif not remote_branches:
        return
    existing = api(f"repos/{OPERATOR}/pulls?state=open&head=ShiftWise-AI:{branch}&base=main")
    if not existing:
        api(f"repos/{OPERATOR}/pulls", "POST", {
            "title": f"fix: update Harvester to {version}", "head": branch, "base": "main",
            "body": f"Published and verified image: `{reference}`.\n\nOnly the Harvester image reference changes.",
        })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["reserve", "operator"])
    parser.add_argument("--source")
    parser.add_argument("--version")
    parser.add_argument("--digest")
    parser.add_argument("--directory", default="operator")
    args = parser.parse_args()
    if args.command == "reserve":
        reserve(args.source)
    else:
        update_operator(args.version, args.digest, args.directory)


if __name__ == "__main__":
    main()