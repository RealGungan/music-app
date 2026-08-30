"""Run the NASMusic server: python3 -m nasmusic [--config path] [port]"""

import argparse
import logging
import os
import sys
import threading
import time


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nasmusic",
                                     description="NASMusic server")
    parser.add_argument("--music-root", default=None,
                        help="library folder (default: $NASMUSIC_MUSIC_ROOT "
                             "or /data/music)")
    parser.add_argument("--staging-dir", default=None,
                        help="staging zone (default $NASMUSIC_STAGING_DIR)")
    parser.add_argument("--playlist-dir", default=None,
                        help="playlists folder")
    parser.add_argument("--port", type=int, default=None,
                        help="HTTP port (default 6680)")
    parser.add_argument("--host", default=None, help="bind host")
    parser.add_argument("--no-expiry", action="store_true",
                        help="disable the background expiry sweep")
    args = parser.parse_args(argv)

    from .httpd import NASMusicServer, make_state
    from .lifecycle import run_expiry
    from .state import Config

    overrides = {}
    if args.music_root:
        overrides["MUSIC_ROOT"] = args.music_root
    if args.staging_dir:
        overrides["STAGING_DIR"] = args.staging_dir
    if args.playlist_dir:
        overrides["PLAYLIST_DIR"] = args.playlist_dir
    if args.port:
        overrides["PORT"] = str(args.port)
    if args.host:
        overrides["HOST"] = args.host

    config = Config(**overrides)
    state = make_state(config)

    if not os.path.isdir(config.music_root):
        logging.getLogger("nasmusic").warning(
            "music root does not exist yet: %s", config.music_root)

    server = NASMusicServer((config.host, config.port), state)

    if not args.no_expiry:
        def sweep():
            while True:
                try:
                    gone = run_expiry(state)
                    if gone:
                        logging.info("expired %d staged files", len(gone))
                except Exception:                     # noqa: BLE001
                    logging.exception("expiry sweep failed")
                time.sleep(3600)
        threading.Thread(target=sweep, daemon=True).start()

    print(f"NASMusic server listening on "
          f"http://{config.host}:{config.port}/staging/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
