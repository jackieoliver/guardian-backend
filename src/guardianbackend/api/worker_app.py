from fastapi import FastAPI

from guardianbackend.config import Settings, get_settings

from . import internal_worker
from .health import build_health_router


def create_worker_app(settings: Settings | None = None) -> FastAPI:
    resolved_settings = settings or get_settings()
    app = FastAPI(title="Guardian Worker", version="0.1.0")
    app.router.redirect_slashes = False
    app.state.settings = resolved_settings
    app.include_router(build_health_router(lambda: resolved_settings))
    app.include_router(internal_worker.router)
    return app


app = create_worker_app()
