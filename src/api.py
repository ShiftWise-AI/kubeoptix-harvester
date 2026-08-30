#!/usr/bin/env python3

import json
import logging
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading

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
PROGRESS_PREFIX = "[PROGRESS] "


app = FastAPI(
    title="KubeOptix Harvester API",
    description="KubeOptix Harvester REST API.",
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
collection_state = {"progress": 0, "running": False}
collection_state_lock = threading.Lock()


def update_collection_progress(progress: int) -> None:
    if 0 <= progress <= 100:
        with collection_state_lock:
            collection_state["progress"] = progress


def run_collection(namespaces: str) -> None:
    logger.info("Starting collection script for namespaces: %s", namespaces)
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"

    try:
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
                if msg.startswith(PROGRESS_PREFIX):
                    try:
                        update_collection_progress(int(msg.removeprefix(PROGRESS_PREFIX)))
                    except ValueError:
                        logger.warning("Invalid collection progress marker: %s", msg)
                if msg:
                    logger.info("[collector] %s", msg)

        return_code = process.wait()
        if return_code == 0:
            update_collection_progress(100)
            logger.info("Collection script finished successfully")
        else:
            logger.error("Collection script failed with exit code: %s", return_code)
    except Exception:
        logger.exception("Failed to execute collection script")
    finally:
        with collection_state_lock:
            collection_state["running"] = False


def fetch_namespaces() -> dict[str, object]:
    logger.info("Starting namespaces script")

    if not os.path.isfile(NAMESPACES_SCRIPT):
        raise HTTPException(status_code=500, detail="script oc_collect_namespaces.sh not found")

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
        raise HTTPException(status_code=500, detail=output or "failed to list namespaces")

    try:
        payload = json.loads(output)
    except json.JSONDecodeError as exc:
        logger.exception("Namespaces script returned invalid JSON")
        raise HTTPException(status_code=500, detail="namespace script did not return valid JSON") from exc

    if not isinstance(payload, dict):
        raise HTTPException(status_code=500, detail="namespace script returned an invalid format")

    return payload


def build_tree(path: Path) -> dict:
    """Recursively build a directory tree similar to the Unix tree command."""
    if path.is_file():
        return {
            "name": path.name,
            "type": "file",
        }

    children = []
    try:
        entries = sorted(
            path.iterdir(),
            key=lambda entry: (
                not entry.is_dir(),
                entry.name.lower(),
            ),
        )
        for entry in entries:
            if entry.name.startswith("."):
                continue
            children.append(build_tree(entry))
    except PermissionError:
        return {
            "name": path.name,
            "type": "directory",
            "error": "Permission denied",
        }

    return {
        "name": path.name,
        "type": "directory",
        "children": children,
    }


@app.get("/assessment", response_model=dict, tags=["collector"])
def assessment_tree():
    """Return the assessment directory tree."""
    root = Path(ASSESSMENT_DIR)
    if not root.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Assessment directory not found: {ASSESSMENT_DIR}",
        )
    if not root.is_dir():
        raise HTTPException(
            status_code=400,
            detail=f"ASSESSMENT_DIR is not a directory: {ASSESSMENT_DIR}",
        )
    return build_tree(root)


@app.get("/health", tags=["infra"])
def healthcheck() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/collect", response_model=CollectResponse, tags=["collector"])
def collect(payload: CollectRequest, background_tasks: BackgroundTasks) -> CollectResponse:
    namespaces = payload.namespaces.strip()
    if not namespaces:
        raise HTTPException(status_code=400, detail="namespaces cannot be empty")

    if not os.path.isfile(RUN_SCRIPT):
        raise HTTPException(status_code=500, detail="script run-ocp.sh not found")

    with collection_state_lock:
        if collection_state["running"]:
            raise HTTPException(status_code=409, detail="a collection is already running")
        collection_state["progress"] = 0
        collection_state["running"] = True

    background_tasks.add_task(run_collection, namespaces)
    return CollectResponse(
        status="accepted",
        message="Collection started in the background",
    )


@app.get("/collect/status", response_model=int, tags=["collector"])
def collection_status() -> int:
    with collection_state_lock:
        return int(collection_state["progress"])


@app.get("/namespaces", response_model=NamespacesResponse, tags=["collector"])
def list_namespaces() -> NamespacesResponse:
    payload = fetch_namespaces()
    namespaces = payload.get("namespaces", [])

    if not isinstance(namespaces, list):
        raise HTTPException(status_code=500, detail="namespaces field is invalid in the returned JSON")

    namespace_names: list[str] = []
    for namespace in namespaces:
        if isinstance(namespace, str):
            namespace_names.append(namespace)
        else:
            raise HTTPException(status_code=500, detail="namespaces field must contain only strings")

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
            message="Assessment directory does not exist; nothing to clean",
            deleted_items=0,
        )

    if not ASSESSMENT_DIR.is_dir():
        raise HTTPException(status_code=500, detail="/app/data/assessment is not a directory")

    deleted_items = 0

    try:
        for child in ASSESSMENT_DIR.iterdir():
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
            deleted_items += 1
    except Exception as exc:
        logger.exception("Error while cleaning assessment data")
        raise HTTPException(status_code=500, detail=f"failed to clean assessment data: {exc}") from exc

    return CleanupResponse(
        status="ok",
        message="Assessment data removed successfully",
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