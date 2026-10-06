from .models import SourceType


def default_source_types() -> list[SourceType]:
    return [
        SourceType(source_id="screenpipe", source_name="Screenpipe"),
        SourceType(source_id="gopro", source_name="GoPro"),
        SourceType(source_id="jelly-phone-capture", source_name="Jelly Phone Capture"),
        SourceType(source_id="gumstick-mic", source_name="Gumstick Mic"),
        SourceType(source_id="insta360-go-ultra", source_name="Insta360 Go Ultra"),
        SourceType(source_id="dji-mic-3", source_name="DJI Mic 3"),
    ]
