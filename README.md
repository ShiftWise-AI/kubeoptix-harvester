# KubeOptix Harvester

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

## Configuration

The application relies on a few environment and Helm settings:

- `API_HOST` and `API_PORT` in the Python process, defaulting to `0.0.0.0:8000`.
- `LOG_LEVEL`, default `INFO`.
- `HOME` and `KUBECONFIG` are set in the pod environment, as shown in the Helm values file.
- `podEnv.TZ` is set to `America/Sao_Paulo` in the example values.
- `service.api.port` and `targetPort` are configured as `8000`.
- `persistence.mountPath` is `/app/data`.
- `build.sourceSecret` can provide a GitHub token when the source repository is private.
- The chart creates or reuses a namespace via `namespace.create` and `namespace.name`.

The main application endpoints are:

- `GET /health`
- `POST /collect`
- `GET /collect/status`
- `GET /namespaces`
- `DELETE /assessment`
- `GET /assessment`

## Installation

Use the included Helm chart to install the workload in OpenShift.

```bash
helm upgrade --install kubeoptix-harvester ./helm/kubeoptix-harvester \
  -n shiftwise-ai \
  --create-namespace \
  -f ./helm/kubeoptix-harvester/values.example.yaml
```

The repository also includes an install helper:

```bash
./install.sh -f ./helm/kubeoptix-harvester/values.example.yaml
```

The helper validates `oc`, `helm`, the target namespace, and then performs the Helm installation and the OpenShift build process.

## Helm Configuration

The chart name is `kubeoptix-harvester` and is defined in `helm/kubeoptix-harvester/Chart.yaml`.

The main Kubernetes resources created by the chart are:

- `Namespace` when `namespace.create` is enabled.
- `ImageStream` and `BuildConfig` when `build.enabled` is enabled.
- `ServiceAccount` and optional `ClusterRoleBinding`.
- `StatefulSet` for the application workload.
- `Service` for the API endpoint.
- `PersistentVolumeClaim` for `/app/data` when persistence is enabled.
- Optional `Secret` for Git source authentication.

The values file exposes the key deployment settings, including:

- `deploy.enabled`
- `namespace.create` and `namespace.name`
- `build.enabled`, `build.source.gitUri`, and `build.source.gitRef`
- `service.api.name`, `type`, `port`, and `targetPort`
- `persistence.enabled`, `size`, and `mountPath`
- `scalePolicy.enabled` and `scalePolicy.maxReplicas`

## Running Locally

The project is primarily designed for OpenShift deployment, but the Python API can be started locally for development if `oc` is authenticated and the Python dependencies are installed.

```bash
python3 -m pip install -r requirements.txt
python3 src/api.py
```

Then check the health endpoint:

```bash
curl http://localhost:8000/health
```

## Development

To prepare the environment:

```bash
python3 -m pip install -r requirements.txt
```

To run the collection flow directly from the repository:

```bash
./run-ocp.sh --namespaces "app-a app-b" --tail-lines 300
```

This script calls the namespace collectors and writes artifacts to `/app/data/assessment`.

## Container

The repository includes a `Containerfile` that builds a runtime image for the service.

Example:

```bash
docker build -t kubeoptix-harvester -f Containerfile .
```

The image:

- installs Python and the OpenShift CLI,
- copies the source and collector scripts,
- installs the Python dependencies,
- exposes port `8000`, and
- runs the FastAPI service with `python /app/src/api.py`.

## Deployment

The deployment flow is organized around the Helm chart and the OpenShift build pipeline:

1. The chart creates or reuses the target namespace.
2. The build resources create an image from the repository and push it to the target `ImageStream`.
3. The app workload is deployed as a `StatefulSet`.
4. The API is exposed through the `Service` on port `8000`.
5. The persistent volume stores assessment artifacts under `/app/data`.

## Troubleshooting

- If `oc` is not logged in or the CLI is missing, collection and installation commands fail immediately.
- If the app is started without a valid cluster context, collection jobs cannot read namespace resources.
- `POST /collect` returns `409` while a collection is already running.
- Private sources require a valid `build.sourceSecret` token with read access.

## License

No explicit license file is present in this repository, so no license is documented here.
|---|---|---|
| 1/3 | Additional namespaced resources (300+ CRD kinds) | `<output_dir>/<namespace>/resources/<kind>/<name>.yaml` |
| 2/3 | Core manifests (Deployment, Service, Route, etc.) | `<output_dir>/<namespace>/apps/<app>/<kind>/<name>.yaml` |
| 3/3 | Pod logs (grouped by `app` label) | `<output_dir>/<namespace>/apps/<app>/pod-logs/<pod>.log` |

Resources without an `app` label are stored under `__no_app__`.

---

### `oc_remove_secret_manifests.sh`

Recursively scans the artifact directory for YAML files containing `kind: Secret` and deletes them.

> **Default mode is `--dry-run`** (called from `run.sh`). To actually delete, remove the flag.

```
Usage:
  ./collectors/oc_remove_secret_manifests.sh -d <directory> [--dry-run]
```

---

### `anonymization.py`

The script is retained in the repository for now, but is not executed by the collection pipelines.

When run manually, it walks the entire artifact directory and masks sensitive data patterns using regex substitution.

| Pattern key | What it matches |
|---|---|
| `CPF` | Brazilian CPF numbers |
| `EMAIL` | Email addresses |
| `TOKEN` / `TOKEN_EXPLICITO` | Bearer tokens, JWT, service account tokens |
| `CHAVE_API` | API key / secret fields |
| `CERTIFICADO_PEM` | PEM certificates |
| `CHAVE_PRIVADA_PEM` | PEM private keys |
| `SEGREDO_INFRA` | password, secret, dockerconfigjson, etc. |
| `IBAN` / `SWIFT_BIC` | International banking identifiers |

Matches are replaced with `[<TYPE>_REMOVIDO]`.

```
Usage:
  python3 src/anonymization.py <directory> [--backup]
```

---

## Output Structure

After a full run, the artifact directory looks like:

```
/app/data/assessment/
├── worknodes/
│   ├── worker-node-01.yaml
│   └── worker-node-02.yaml
└── <namespace>/
    ├── apps/
    │   ├── <app-name>/
    │   │   ├── deployments/
    │   │   ├── configmaps/
    │   │   ├── services/
    │   │   ├── routes/
    │   │   └── pod-logs/
    │   └── __no_app__/
    └── resources/
        ├── persistentvolumeclaims/
        ├── serviceaccounts/
        └── ...
```

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `NAMESPACES` | `default ` | Namespaces collected when `--namespaces` is omitted |
| `TAIL_LINES` | `300` | Log lines per pod |
| `OUTPUT_DIR` | `/app/data/assessment` | Artifact root directory (namespaces under `/app/data/assessment/<namespace>`) |
| `VENV_DIR` | `./.venv` | Python virtual environment path |

The collector runs as a single pod only (StatefulSet replicas fixed at 1, no autoscaler configured).
At the end of each run, the script prints an explicit en-US completion message with the final artifacts directory.

---

## Security Notes

- Secret manifests are **removed** (or reported in dry-run) before sharing artifacts.
- `anonymization.py` is not executed automatically; review and sanitize artifacts before sharing them externally.
- Always review the output directory before sharing it externally.
- The `.gitignore` excludes generated artifacts under `data/` (for local runs) and `.bak` backup files.

---

*Other language versions: [Português BR](README.pt-br.md) · [Italiano](README.it.md)*
