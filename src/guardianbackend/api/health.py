from collections.abc import Callable

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from guardianbackend.config import Settings


def build_health_router(settings_provider: Callable[[], Settings]) -> APIRouter:
    router = APIRouter()

    def _health_payload() -> dict[str, object]:
        settings = settings_provider()
        return {
            "status": "ok",
            "checks": {
                "environment": settings.environment,
                "cloud_enabled": settings.uses_cloud,
            },
        }

    @router.get("/health")
    def get_health() -> dict[str, object]:
        return _health_payload()

    @router.get("/ready")
    def get_ready() -> JSONResponse:
        ready = True
        return JSONResponse(
            status_code=status.HTTP_200_OK if ready else status.HTTP_503_SERVICE_UNAVAILABLE,
            content=_health_payload() | {"status": "ready" if ready else "not_ready"},
        )

    return router
