# KubeOptix Harvester

See [CONTRIBUTING.md](CONTRIBUTING.md) for the branch workflow and contribution process.

KubeOptix Harvester is a small OpenShift collection and sanitization toolkit. It connects to a live cluster, inventories namespaces and workloads, exports manifests and pod logs, and writes the results under `/app/data/assessment` for downstream analysis. The project also scans collected files for common secret patterns so sensitive values can be removed before the data is shared or stored outside the cluster.

The main runtime is a FastAPI service that exposes endpoints to trigger a collection job, check progress, list namespaces, and inspect the generated artifacts. The Helm chart packages the application for deployment on OpenShift and wires it to a StatefulSet, Service, PVC, and build pipeline.

## Features

- Collects worker node manifests from the cluster.
- Enumerates namespaces and lists cluster resources.
- Collects namespace-level resources and pod logs.
- Removes common secret and sensitive data patterns from collected files.
- Exposes a REST API for starting and monitoring collection runs.
- Deploys on OpenShift through the included Helm chart.

## Requirements

- `oc` with a valid login to the target OpenShift cluster.
- `python3` 3.9 or later.
- `bash` with standard shell utilities.
- `helm` for chart installation and upgrades.
- Access to read namespace and workload objects in the target cluster.
- Optional: Docker or Podman for building the image from the `Containerfile`.

## Technologies

- Bash for cluster collection scripts.
- Python 3 for sanitization and the FastAPI API.
- FastAPI and Uvicorn for the HTTP service.
- OpenShift CLI (`oc`) and Kubernetes resource APIs.
- Helm for installation and deployment.
- OpenShift `BuildConfig`, `ImageStream`, and `StatefulSet` resources.

## Project Structure

```text
kubeoptix-harvester/
├── Containerfile                   # Runtime image definition
├── install.sh                      # OpenShift/Helm installation helper
├── run.sh                          # Local collection wrapper
├── run-ocp.sh                      # Primary cluster collection entry point
├── requirements.txt                # Python runtime dependencies
├── src/
│   ├── anonymization.py            # Sensitive data masking utility
│   └── api.py                     # FastAPI service and collection endpoints
├── collectors/
│   ├── oc_collect_all_namespaces.sh
│   ├── oc_collect_namespace.sh
│   ├── oc_collect_namespaces.sh
│   ├── oc_collect_worknodes.sh
│   └── oc_remove_secret_manifests.sh
├── helm/
│   └── kubeoptix-harvester/
│       ├── Chart.yaml
│       ├── values.example.yaml
│       └── templates/
├── .containerignore
├── .copilotignore
├── .helmignore
├── README.md
└── .gitignore
```

## Collection Flow

`run-ocp.sh` performs three steps:

1. Collects YAML manifests for nodes labeled `node-role.kubernetes.io/worker`.
2. Collects the selected namespaces with `oc_collect_all_namespaces.sh`.
3. Scans YAML files for `kind: Secret` and reports them with the cleanup script in dry-run mode.

The cleanup step does not delete files in the normal collection flow. To delete matching Secret manifests, run `oc_remove_secret_manifests.sh` without `--dry-run` after reviewing the output.

When `--namespaces` is omitted, the collector uses the `default` namespace. Namespace arguments are passed as a space-separated string, for example `"app-a app-b"`.

## Direct Collection

Authenticate first and check the active identity:

```bash
oc login https://api.example.com:6443
oc whoami
```

Run a collection from the repository checkout:

```bash
./run-ocp.sh --namespaces "app-a app-b" --tail-lines 300
```

The output root is always `/app/data/assessment`. The `-o`/`--output-dir` option is accepted by the lower-level collectors for composition, but `run-ocp.sh` normalizes the final output path to `/app/data/assessment`.

Individual collectors can be used when needed:

```bash
./collectors/oc_collect_worknodes.sh -o ./output
./collectors/oc_collect_namespace.sh -n app-a -o ./output --tail-lines 100
./collectors/oc_collect_namespaces.sh
./collectors/oc_remove_secret_manifests.sh -d ./output --dry-run
```

## Output Structure

The resulting directory has this general shape:

```text
/app/data/assessment/
├── worknodes/
│   ├── worker-node-01.yaml
│   └── worker-node-02.yaml
└── <namespace>/
    ├── apps/
    │   ├── <app-label>/
    │   │   ├── deployments/
    │   │   ├── deploymentconfigs/
    │   │   ├── statefulsets/
    │   │   ├── configmaps/
    │   │   ├── routes/
    │   │   ├── services/
    │   │   ├── jobs/
    │   │   ├── replicasets/
    │   │   └── pod-logs/
    │   └── __no_app__/
    └── resources/
        └── <resource-kind>/<resource-name>.yaml
```

Application resources are grouped using the `app` label. Objects without that label are stored under `apps/__no_app__`. Pod logs contain up to `--tail-lines` lines per pod, with a default of `300`.

## REST API

The service listens on `0.0.0.0:8000` by default. The current implementation reads `LOG_LEVEL` and does not define separate `API_HOST` or `API_PORT` settings.

### Health

```bash
curl http://localhost:8000/health
```

Response: `{"status":"ok"}`

### List namespaces

```bash
curl http://localhost:8000/namespaces
```

The response contains `status`, `count`, and a string array named `namespaces`.

### Start a collection

```bash
curl -X POST http://localhost:8000/collect \
  -H 'Content-Type: application/json' \
  -d '{"namespaces":"app-a app-b"}'
```

The job runs in the background and returns:

```json
{
  "status": "accepted",
  "message": "Collection started in the background"
}
```

An empty namespace string returns `400`. Only one collection can run at a time; a second request returns `409`.

### Read progress

```bash
curl http://localhost:8000/collect/status
```

The response is a JSON integer from `0` to `100`. Progress is process-local and is reset when the API process restarts; it is not persisted.

### Inspect and delete collected files

```bash
curl http://localhost:8000/assessment
curl -X DELETE http://localhost:8000/assessment
```

`GET /assessment` returns a recursive JSON tree rooted at `/app/data/assessment` and returns `404` before that directory exists. `DELETE /assessment` removes every direct child of the directory, including namespace and `worknodes` directories.

## Local Development

Install dependencies and start the API:

```bash
python3 -m pip install -r requirements.txt
python3 src/api.py
```

The health endpoint works from a repository checkout. Collection endpoints invoke absolute paths (`/app/run-ocp.sh` and `/app/collectors/...`), so collection through the API requires the container layout or equivalent files mounted at `/app`. For a checkout, use `run-ocp.sh` directly or run the API from an image built with the `Containerfile`.

## Sanitization and Data Handling

Secret manifest removal and value anonymization are separate operations:

- `oc_remove_secret_manifests.sh` detects YAML files whose `kind` line is `Secret`. It reports matches in dry-run mode and deletes them only without `--dry-run`.
- `src/anonymization.py` is not called automatically by `run-ocp.sh` or the API. Run it manually against a copied or reviewed directory:

```bash
python3 src/anonymization.py /app/data/assessment --backup
```

The anonymizer applies regular expressions for identifiers and contact data, tokens and API keys, certificates and private keys, and common infrastructure or banking fields. `--backup` creates a `.bak` file before each modified file. Regex-based masking is not a guarantee that all sensitive data has been removed.

## OpenShift Deployment

The example values file is configured for a `shiftwise-ai` namespace, a `10Gi` PVC, a `ClusterIP` service on port `8000`, and a service account with the `cluster-reader` cluster role.

### Helm only

```bash
helm upgrade --install kubeoptix-harvester ./helm/kubeoptix-harvester \
  -n shiftwise-ai --create-namespace \
  -f ./helm/kubeoptix-harvester/values.example.yaml
```

The chart can create the namespace, `ImageStream`, `BuildConfig`, service account, optional `ClusterRoleBinding`, `StatefulSet`, `Service`, and PVC. Set `build.sourceSecret.create=true` and provide the Git username/token when the source repository is private.

### Installation helper

`install.sh` requires a values file, validates `oc` and Helm, creates the target namespace when needed, installs the build resources, starts and waits for an OpenShift build, deploys the workload, waits for the StatefulSet rollout, and performs cleanup of completed builds, completed pods, unused release ConfigMaps, and unused release Secrets.

```bash
./install.sh -f ./helm/kubeoptix-harvester/values.example.yaml
./install.sh -f values.yaml --skip-cleanup
./install.sh -f values.yaml --cleanup-dry-run
BUILD_FROM_LOCAL=true ./install.sh -f values.yaml
```

Useful environment variables are `RELEASE`, `NS`, `CHART_PATH`, `WAIT_TIMEOUT`, `BUILD_FROM_LOCAL`, `POST_INSTALL_CLEANUP`, and `CLEANUP_DRY_RUN`. With `BUILD_FROM_LOCAL=true`, the helper starts the BuildConfig with `--from-dir=.`; otherwise it uses `build.source.gitUri` and `build.source.gitRef`.

## Configuration Reference

| Setting | Example default | Purpose |
|---|---|---|
| `namespace.name` | `shiftwise-ai` | OpenShift project/namespace |
| `build.enabled` | `true` | Creates the ImageStream and BuildConfig |
| `build.source.gitUri` | Repository URL | Git source for the build |
| `build.source.gitRef` | `feature/ocp` | Git branch or ref |
| `service.api.port` | `8000` | Service port |
| `persistence.size` | `10Gi` | PVC capacity |
| `persistence.mountPath` | `/app/data` | Application data mount |
| `scalePolicy.maxReplicas` | `1` | Maximum replicas configured by the chart policy |
| `podEnv.HOME` | `/tmp` | Writable home directory in the container |
| `podEnv.KUBECONFIG` | `/tmp/.kube/config` | Kubeconfig path used by CLI tooling |
| `LOG_LEVEL` | `INFO` | Python logging level |
| `--tail-lines` | `300` | Maximum pod log lines per pod |

The service-account token is used by the example startup script to run `oc login` against the in-cluster Kubernetes API. Review the granted RBAC permissions before deploying to a production cluster.

## Troubleshooting

- `oc whoami` fails: authenticate to the intended cluster and verify the current context.
- Permission errors during collection: grant the service account read access to the required resources and logs; worker-node collection additionally requires node read access.
- `POST /collect` returns `409`: another collection is running; poll `/collect/status` until it finishes.
- `GET /assessment` returns `404`: no collection has created `/app/data/assessment` yet.
- The API reports `run-ocp.sh not found`: the service is running outside the expected `/app` image layout; use the container image or run the wrapper directly from the checkout.
- Use `run-ocp.sh` for direct collection. `run.sh` is a legacy wrapper and currently references `VENV_DIR` while its declaration is disabled.
- A private Git build fails: configure `build.sourceSecret` with credentials that can read the repository, or use `BUILD_FROM_LOCAL=true` from the workspace.
- The PVC cannot mount: verify the storage class and that the configured access mode is supported by the cluster.

## License

This project is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full license text.

