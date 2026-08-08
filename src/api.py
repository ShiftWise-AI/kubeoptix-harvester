#!/usr/bin/env python3

import json
import logging
import os
from pathlib import Path
import shutil
import subprocess
import sys

from fastapi import BackgroundTasks, FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn


LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("kubeoptix.api")
RUN_SCRIPT = "/app/run-ocp.sh"


app = FastAPI(
    title="KubeOptix Harvester API",
    description="API REST do KubeOptix Harvester.",
    version="1.0.0",
)


class CollectRequest(BaseModel):
    namespaces: str


class CollectResponse(BaseModel):
    status: str
    message: str


class CleanupResponse(BaseModel):
    status: str
    message: str
    deleted_items: int


class NamespacesResponse(BaseModel):
    status: str
    count: int
    namespaces: list[str]


ASSESSMENT_DIR = Path("/app/data/assessment")
NAMESPACES_SCRIPT = "/app/collectors/oc_collect_namespaces.sh"


def run_collection(namespaces: str) -> None:
    logger.info("Starting collection script for namespaces: %s", namespaces)
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"

    process = subprocess.Popen(
        ["bash", RUN_SCRIPT, "--namespaces", namespaces],
        cwd="/app",
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    if process.stdout is not None:
        for line in process.stdout:
            msg = line.rstrip().replace("\r", "")
            if msg:
                logger.info("[collector] %s", msg)

    return_code = process.wait()
    if return_code == 0:
        logger.info("Collection script finished successfully")
    else:
        logger.error("Collection script failed with exit code: %s", return_code)


def fetch_namespaces() -> dict[str, object]:
    logger.info("Starting namespaces script")

    if not os.path.isfile(NAMESPACES_SCRIPT):
        raise HTTPException(status_code=500, detail="script oc_collect_namespaces.sh nao encontrado")

    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"

    result = subprocess.run(
        ["bash", NAMESPACES_SCRIPT],
        cwd="/app",
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )

    output = (result.stdout or "").strip()
    if result.returncode != 0:
        logger.error("Namespaces script failed with exit code: %s", result.returncode)
        raise HTTPException(status_code=500, detail=output or "falha ao listar namespaces")

    try:
        payload = json.loads(output)
    except json.JSONDecodeError as exc:
        logger.exception("Namespaces script returned invalid JSON")
        raise HTTPException(status_code=500, detail="script de namespaces nao retornou JSON valido") from exc

    if not isinstance(payload, dict):
        raise HTTPException(status_code=500, detail="script de namespaces retornou formato invalido")

    return payload


@app.get("/health", tags=["infra"])
def healthcheck() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/collect", response_model=CollectResponse, tags=["collector"])
def collect(payload: CollectRequest, background_tasks: BackgroundTasks) -> CollectResponse:
    namespaces = payload.namespaces.strip()
    if not namespaces:
        raise HTTPException(status_code=400, detail="namespaces nao pode ser vazio")

    if not os.path.isfile(RUN_SCRIPT):
        raise HTTPException(status_code=500, detail="script run-ocp.sh nao encontrado")

    background_tasks.add_task(run_collection, namespaces)
    return CollectResponse(
        status="accepted",
        message="Coleta iniciada em background",
    )


@app.get("/namespaces", response_model=NamespacesResponse, tags=["collector"])
def list_namespaces() -> NamespacesResponse:
    payload = fetch_namespaces()
    namespaces = payload.get("namespaces", [])

    if not isinstance(namespaces, list):
        raise HTTPException(status_code=500, detail="campo namespaces invalido no JSON retornado")

    namespace_names: list[str] = []
    for namespace in namespaces:
        if isinstance(namespace, str):
            namespace_names.append(namespace)
        else:
            raise HTTPException(status_code=500, detail="campo namespaces deve conter apenas strings")

    return NamespacesResponse(
        status=str(payload.get("status", "ok")),
        count=int(payload.get("count", len(namespace_names))),
        namespaces=namespace_names,
    )


@app.delete("/assessment", response_model=CleanupResponse, tags=["collector"])
def cleanup_assessment_data() -> CleanupResponse:
    if not ASSESSMENT_DIR.exists():
        return CleanupResponse(
            status="ok",
            message="Diretorio de assessment nao existe; nada para limpar",
            deleted_items=0,
        )

    if not ASSESSMENT_DIR.is_dir():
        raise HTTPException(status_code=500, detail="/app/data/assessment nao e um diretorio")

    deleted_items = 0

    try:
        for child in ASSESSMENT_DIR.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
            deleted_items += 1
    except Exception as exc:
        logger.exception("Erro ao limpar dados de assessment")
        raise HTTPException(status_code=500, detail=f"falha ao limpar assessment: {exc}") from exc

    return CleanupResponse(
        status="ok",
        message="Dados de assessment removidos com sucesso",
        deleted_items=deleted_items,
    )


if __name__ == "__main__":
    logger.info("Starting KubeOptix Harvester API")
    uvicorn.run(
        app,
        host=os.getenv("API_HOST", "0.0.0.0"),
        port=int(os.getenv("API_PORT", "8000")),
        reload=False,
        log_level=LOG_LEVEL.lower(),
        access_log=False,
    )