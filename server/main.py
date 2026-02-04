"""
Веб-сервис ScreenshotMaker: загрузка APK (drag & drop), запуск генерации скриншотов, выдача результата.
"""
import os
import shutil
import subprocess
import uuid
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, File, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi import FastAPI

# Корень проекта (родитель каталога server)
PROJECT_ROOT = Path(__file__).resolve().parent.parent
UPLOADS_DIR = PROJECT_ROOT / "uploads"
JOBS_DIR = PROJECT_ROOT / "jobs"
IMAGE_NAME = os.environ.get("IMAGE_NAME", "screenshot-maker")

UPLOADS_DIR.mkdir(exist_ok=True)
JOBS_DIR.mkdir(exist_ok=True)

app = FastAPI(title="ScreenshotMaker", version="1.0.0")
api = APIRouter(prefix="/api", tags=["api"])


def run_screenshot_job(job_id: str, apk_path: Path, out_dir: Path) -> None:
    """Запуск Docker-контейнера для генерации скриншотов. Пишет status.txt и error.txt в out_dir."""
    status_file = out_dir / "status.txt"
    error_file = out_dir / "error.txt"
    try:
        status_file.write_text("running")
        kvm = ["--device", "/dev/kvm"] if (Path("/dev/kvm")).exists() else []
        cmd = [
            "docker", "run", "--rm", "--platform", "linux/amd64",
            *kvm,
            "-v", f"{apk_path}:/workspace/app.apk:ro",
            "-v", f"{out_dir}:/screenshots",
            "-e", "APK_PATH=/workspace/app.apk",
            "-e", "SCREENSHOTS_DIR=/screenshots",
            IMAGE_NAME,
        ]
        # Без KVM эмулятор с 3 локалями и перезагрузками может работать 15–25 мин
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, cwd=str(PROJECT_ROOT))
        if result.returncode == 0:
            status_file.write_text("done")
        else:
            (out_dir / "error.txt").write_text(result.stderr or result.stdout or "Unknown error")
            status_file.write_text("failed")
    except subprocess.TimeoutExpired:
        status_file.write_text("failed")
        error_file.write_text("Timeout (30 min). Без KVM попробуйте сервер с большими ресурсами или включите KVM.")
    except Exception as e:
        status_file.write_text("failed")
        error_file.write_text(str(e))


@api.post("/upload")
async def upload_apk(background_tasks: BackgroundTasks, file: UploadFile = File(...)):
    """Принимает APK, сохраняет, запускает задачу в фоне, возвращает job_id."""
    if not file.filename or not file.filename.lower().endswith(".apk"):
        raise HTTPException(status_code=400, detail="Нужен файл .apk")
    job_id = str(uuid.uuid4())
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    apk_path = job_dir / "app.apk"
    try:
        with open(apk_path, "wb") as f:
            shutil.copyfileobj(file.file, f)
    finally:
        await file.close()
    background_tasks.add_task(run_screenshot_job, job_id, apk_path, job_dir)
    return JSONResponse(content={"job_id": job_id})


LOCALE_FILES = ["main_ru.png", "main_en.png", "main_es.png"]

def _completed_locales(job_dir: Path) -> list[str]:
    """Список локалей, для которых скриншот уже готов (файл есть и не пустой)."""
    out = []
    for f in LOCALE_FILES:
        p = job_dir / f
        if p.exists() and p.stat().st_size > 0:
            out.append(f.replace("main_", "").replace(".png", ""))
    return out


@api.get("/jobs/{job_id}/status")
async def job_status(job_id: str):
    """Статус задачи: pending, running, done, failed. completed — список готовых локалей (ru, en, es)."""
    job_dir = JOBS_DIR / job_id
    if not job_dir.is_dir():
        raise HTTPException(status_code=404, detail="Job not found")
    status_file = job_dir / "status.txt"
    if not status_file.exists():
        status = "pending"
    else:
        status = status_file.read_text().strip() or "pending"
    error = ""
    if status == "failed" and (job_dir / "error.txt").exists():
        error = (job_dir / "error.txt").read_text()
    completed = _completed_locales(job_dir)
    return JSONResponse(content={
        "job_id": job_id,
        "status": status,
        "error": error,
        "completed": completed,
    })


@api.get("/jobs/{job_id}/result")
async def job_result_zip(job_id: str):
    """Скачать архив со скриншотами."""
    job_dir = JOBS_DIR / job_id
    if not job_dir.is_dir():
        raise HTTPException(status_code=404, detail="Job not found")
    zip_path = job_dir / "screenshots.zip"
    if not zip_path.exists():
        status_file = job_dir / "status.txt"
        if status_file.exists() and status_file.read_text().strip() == "done":
            # Создать zip на лету, если run.sh не создал
            import zipfile
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                for name in ["main_ru.png", "main_en.png", "main_es.png"]:
                    p = job_dir / name
                    if p.exists():
                        zf.write(p, name)
        if not zip_path.exists():
            raise HTTPException(status_code=404, detail="Result not ready or missing")
    return FileResponse(zip_path, media_type="application/zip", filename="screenshots.zip")


@api.get("/jobs/{job_id}/files/{filename}")
async def job_file(job_id: str, filename: str):
    """Отдать один файл скриншота (main_ru.png, main_en.png, main_es.png)."""
    if filename not in ("main_ru.png", "main_en.png", "main_es.png"):
        raise HTTPException(status_code=400, detail="Invalid filename")
    job_dir = JOBS_DIR / job_id
    if not job_dir.is_dir():
        raise HTTPException(status_code=404, detail="Job not found")
    path = job_dir / filename
    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path, media_type="image/png", filename=filename)


app.include_router(api)
app.mount("/", StaticFiles(directory=PROJECT_ROOT / "server" / "static", html=True), name="static")
