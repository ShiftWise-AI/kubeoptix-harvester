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

RUN dnf install -y \
    python3 \
    python3-pip \
    && dnf update -y \
    && curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz -o /tmp/openshift-client-linux.tar.gz \
    && tar -xzf /tmp/openshift-client-linux.tar.gz -C /usr/local/bin/ oc kubectl \
    && chmod +x /usr/local/bin/oc /usr/local/bin/kubectl \
    && rm -f /tmp/openshift-client-linux.tar.gz \
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

COPY run-ocp.sh .
COPY requirements.txt .
COPY src/*.py $SRC_DIR/
COPY collectors/*.sh $COLLECTOR_DIR/

RUN python3 -m venv $VENV_DIR \
    && $VENV_DIR/bin/pip install --upgrade pip \
    && $VENV_DIR/bin/pip install --no-cache-dir -r requirements.txt 

EXPOSE 8000

CMD ["/app/.venv/bin/python", "/app/src/api.py"]


