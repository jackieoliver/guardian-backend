from fastapi import FastAPI

from guardianbackend.config import Settings, get_settings

from . import imports, me, sources
from .health import build_health_router


def create_app(settings: Settings | None = None) -> FastAPI:
    resolved_settings = settings or get_settings()
    app = FastAPI(title="Guardian Backend", version="0.1.0")
    app.router.redirect_slashes = False
    app.state.settings = resolved_settings
    app.include_router(build_health_router(lambda: resolved_settings))
    app.include_router(me.router)
    app.include_router(sources.router)
    app.include_router(imports.router)
    return app


app = create_app()
