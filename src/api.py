#!/usr/bin/env python3

import logging
import os
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