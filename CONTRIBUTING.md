# Contributing

This repository is one component of the KubeOptix platform.

## Branches

- Keep only `develop` and `main`.
- Start changes from `develop`; `main` is the production/release branch.
- Describe the change, impact, and validation when proposing a merge from `develop` to `main`.

## Validation and releases

Pull requests run branch governance, Python and shell validation, Semgrep, Trivy, and a non-root container build. `main` and `develop` require `check-flow`, `ci-required`, and one approval including CODEOWNER review and approval of the latest push. Merges to `main` run the same required checks before the protected `quay-release` job reserves a SemVer tag, publishes the scanned image, and opens a separate Operator PR pinned by digest. The workflow does not deploy to OpenShift or merge the Operator PR.

Release retries must reuse the original full merge commit SHA through `workflow_dispatch`; do not delete or move version tags. The `quay-release` environment requires a reviewer and contains `OPERATOR_TOKEN`. `QUAY_USERNAME` and `QUAY_PASSWORD` are organization secrets and must be available to this repository.

## Commands

```bash
git fetch origin
git switch develop
git pull --ff-only origin develop
```