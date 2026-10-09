FROM registry.access.redhat.com/ubi9/go-toolset:1.25 AS openshift-client-build

ENV CGO_ENABLED=0 \
    GOTOOLCHAIN=go1.27.2

WORKDIR /opt/app-root/src

COPY --chown=1001:0 .github/patches/docker-archive-compat.patch /opt/app-root/archive-compat.patch

RUN curl --fail --silent --show-error --location \
        https://github.com/openshift/oc/archive/d0f23b14fbf35493e5b713e25ecf662ec239e76c.tar.gz \
        --output /tmp/oc-source.tar.gz \
    && tar -xzf /tmp/oc-source.tar.gz --strip-components=1 \
    && go get github.com/moby/buildkit@v0.28.1 github.com/moby/go-archive@v0.3.0 \
        github.com/moby/spdystream@v0.5.1 github.com/sigstore/fulcio@v1.8.6 \
        go.opentelemetry.io/otel@v1.44.0 golang.org/x/crypto@v0.57.0 \
        golang.org/x/net@v0.60.0 \
        github.com/go-git/go-git/v5@v5.19.2 github.com/go-git/go-billy/v5@v5.9.0 \
        google.golang.org/grpc@v1.83.2 \
    && archive_dir="$(go list -mod=mod -f '{{.Dir}}' github.com/docker/docker/pkg/archive)" \
    && chmod u+w "$archive_dir" \
    && chmod u+w "$archive_dir/archive_deprecated.go" \
    && git -C "$archive_dir" apply /opt/app-root/archive-compat.patch \
    && go list -mod=mod -deps ./cmd/oc > /tmp/oc-dependencies.txt \
    && ! grep -E '^github.com/docker/docker/(daemon|cmd/dockerd)(/|$)' /tmp/oc-dependencies.txt \
    && ! grep -E '^github.com/distribution/distribution/v3/registry/((handlers|proxy)(/|$)|storage$|storage/cache/redis(/|$))' /tmp/oc-dependencies.txt \
    && go build -mod=mod -tags containers_image_openpgp -trimpath -ldflags '-s -w' \
        -o /opt/app-root/src/oc ./cmd/oc

FROM registry.access.redhat.com/ubi10:1785332448

USER 0

WORKDIR /app

ENV LOG_DIR=/app/logs/ \
    SRC_DIR=/app/src/ \
    COLLECTOR_DIR=/app/collectors/ \
    DATA_DIR=/app/data/ \
    VENV_DIR=/app/.venv \
    HOME=/tmp \
    KUBECONFIG=/tmp/.kube/config \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

ENV PATH=/app/.venv/bin:$PATH

RUN dnf update -y \
    && dnf install -y \
    python3 \
    python3-pip \
    && dnf clean all \
    && useradd -m -s /bin/bash kubeoptix \
    && mkdir -p $LOG_DIR \
    && mkdir -p $DATA_DIR \
    && mkdir -p $SRC_DIR \
    && mkdir -p $COLLECTOR_DIR \
    && mkdir -p $VENV_DIR \
    && mkdir -p /tmp/.kube \
    && chown -R kubeoptix:kubeoptix /app \
    && chmod -R 777 /tmp \
    && chmod -R u+rwX /app

USER kubeoptix

COPY --from=openshift-client-build /opt/app-root/src/oc /usr/local/bin/oc
COPY --from=openshift-client-build /opt/app-root/src/oc /usr/local/bin/kubectl

COPY run-ocp.sh .
COPY requirements.txt .
COPY src/*.py $SRC_DIR/
COPY collectors/*.sh $COLLECTOR_DIR/

RUN python3 -m venv $VENV_DIR \
    && $VENV_DIR/bin/pip install --upgrade pip \
    && $VENV_DIR/bin/pip install --no-cache-dir -r requirements.txt 

EXPOSE 8000

CMD ["/app/.venv/bin/python", "/app/src/api.py"]


