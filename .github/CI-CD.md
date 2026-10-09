# CI/CD Audit and Operations

## Findings (2026-10-09)

Main push was already configured and the latest run succeeded. The real gaps
were missing validation/security gates, mutable Action tags, publishing
independent of GitFlow, and cancellation of main runs. Across seven repositories,
all 21 branches required only `check-flow`, zero approvals, and no up-to-date
branch. Repository secrets were empty; organization secrets could not be audited
with the available token (403).

## Pipeline Contract

PRs to develop/stage/main, pushes to those branches, and merge queues run GitFlow,
Python and shell syntax checks (there is no existing Harvester test suite),
workflow validation, dependency/secret scans, build, non-root inspection, and
final-image vulnerability/configuration/secret scans. `ci-required` rejects
failed, cancelled, or skipped dependencies. Trivy v0.69.3 blocks HIGH/CRITICAL
including unfixed findings. Actions are SHA-pinned, actionlint v1.7.7 is
checksum-verified, token permissions are `contents: read`, and checkout does
not persist credentials.

Only main pushes and valid `vMAJOR.MINOR.PATCH` tags authenticate and publish
the already-scanned image to `quay.io/parraes/kubeoptix-harvester`. Main keeps
`latest` and `sha-<commit>`; releases keep version and SHA tags, and must point
into main history. PRs, stage, develop, and merge queues never access Quay secrets.
Main runs are not actively cancelled; GitHub can coalesce pending concurrent runs.

## GitHub and Quay Configuration

Applied and verified for main/stage/develop: require `check-flow` and
`ci-required` from GitHub Actions, up-to-date branch, at least one approval,
stale-review dismissal, last-push approval, admin enforcement, no force pushes,
and no deletion. Existing checks remain. APPROVE reviews are possible with
failing checks, but integration is blocked by branch protection.

Publish these changes on the existing feature branch, obtain a green PR and
independent review to develop, then promote develop -> stage -> main. PRs
without the updated `ci-required` remain blocked. Confirm pinned Actions are
permitted by organization policy. Protect `v*` tags with a maintainer-only creation
ruleset and prohibit tag mutation. `GITHUB_TOKEN`-created pushes cannot trigger
another push workflow; use an approved GitHub App for automated release tags.

Create a dedicated Quay robot with Write only on this destination. Configure
`QUAY_USERNAME` (full `namespace+robot`) and `QUAY_PASSWORD` (token) as repository
or restricted organization secrets including this repository. Never log tokens,
enable shell tracing, or put credentials in source/command arguments. Rotate
through secure prompts and enable Quay vulnerability notifications.

## Validation and Remaining Acceptance

All 14 workflows passed actionlint; aggregate gate failure cases and 63 GitFlow
cases passed; the 21 remote protections were re-read. Harvester Python/shell
syntax checks passed locally. Source scans found no HIGH/CRITICAL findings or
secrets. The final image was not rebuilt/scanned locally. No changed workflows
were committed, pushed, or executed remotely, and no image was published.
Acceptance requires a failing PR to stay blocked, a reviewed green promotion
to main, and Quay receiving the exact scanned main image. Behavioral unit tests
are still a repository coverage gap, not silently claimed as existing coverage.

## PR Failure Remediation (2026-10-09)

PR #17 was blocked by the official OpenShift client binaries. The image now
builds oc from pinned release-4.22 commit d0f23b14fbf35493e5b713e25ecf662ec239e76c
with Go 1.27.2 and patched client dependencies. The same binary is exposed as
oc and kubectl, matching the original archive's client behavior. Two Docker
archive function signatures are patched for go-archive 0.3 compatibility; the
patch is versioned under .github/patches and the old vulnerable archive library
is not reintroduced. Both client version commands executed successfully. The
custom build currently reports an unknown/unexpanded client version stamp;
it is not represented as an official Red Hat release binary.

The image gate consumes .github/security/harvester.openvex.json. Four statements
apply only to the exact Docker/Distribution module PURLs and server-side CVEs:
Docker daemon archive upload/mount handling, registry pull-through proxy, and
registry storage deletion with Redis caching. The Containerfile fails if Docker
daemon, registry handlers/proxy, registry/storage itself, or Redis cache code
enters the oc dependency graph. Independent memory cache helpers required by
the client are allowed. The declarations are not blanket CVE ignores and must
be revisited if source, module versions, linked packages, or runtime usage change.

The two pip/virtualenv historical build inventories are excluded from runtime
scanning as documented for Analyzer, without removing inventories or excluding
installed code. The corrected client-only image passed the strict scan with
VEX; configuration checks also passed. Authenticated collection against a live
cluster was not exercised. Remote CI and independent review remain required.