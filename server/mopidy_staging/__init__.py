"""Mopidy-Staging: discover -> stage -> keep music lifecycle."""

import logging
import os

import mopidy
from mopidy import config as config_lib, exceptions, ext

logger = logging.getLogger(__name__)


class Extension(ext.Extension):

    dist_name = "Mopidy-Staging"
    ext_name = "staging"
    version = mopidy.__version__

    def get_default_config(self):
        conf_file = os.path.join(os.path.dirname(__file__), "ext.conf")
        return config_lib.read(conf_file)

    def get_config_schema(self):
        schema = super().get_config_schema()
        schema["music_root"] = config_lib.String()
        schema["staging_dir"] = config_lib.String()
        schema["playlist_dir"] = config_lib.String(optional=True)
        schema["folders"] = config_lib.List(optional=True)
        schema["expiry_days"] = config_lib.Integer(minimum=1, optional=True)
        schema["db_path"] = config_lib.String(optional=True)
        schema["yt_dlp_bin"] = config_lib.String()
        schema["node_runtime"] = config_lib.String(optional=True)
        return schema

    def validate_environment(self):
        try:
            import tornado.web  # noqa: F401
        except ImportError as e:
            raise exceptions.ExtensionError("tornado not found", e)

    def setup(self, registry):
        from .actor import StagingFrontend
        from .api import make_staging_app_factory
        from .backend import StagingBackend

        registry.add("backend", StagingBackend)
        registry.add("frontend", StagingFrontend)
        registry.add(
            "http:app",
            {
                "name": "staging",
                "factory": make_staging_app_factory(),
            },
        )
