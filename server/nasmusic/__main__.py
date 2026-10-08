"""Run the NASMusic server: python3 -m nasmusic [--config path] [port]"""

import argparse
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile


def _ensure_ytdlp_js_runtime(log):
    """Make yt-dlp able to resolve YouTube URLs.

    Since 2026, yt-dlp needs a JavaScript runtime (deno by default) to extract
    YouTube streams; without one, cold resolves hang until timeout. The base
    image ships no deno and the container entrypoint runs this module directly,
    so bootstrap the runtime + fresh yt-dlp from inside the process (once, into
    ~/.local/bin, which survives restart restarts of the same container)."""
    deno = shutil.which("deno")
    bindir = os.path.join(os.path.expanduser("~"), ".local", "bin")
    candidate = os.path.join(bindir, "deno")
    if not deno and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
        deno = candidate
        os.environ["PATH"] = bindir + os.pathsep + os.environ.get("PATH", "")
        log.info("deno already present at %s", candidate)
    if not deno:
        arch = "aarch64" if os.uname().machine in ("aarch64", "arm64") else "x86_64"
        url = ("https://github.com/denoland/deno/releases/latest/download/"
               f"deno-{arch}-unknown-linux-gnu.zip")
        try:
            os.makedirs(bindir, exist_ok=True)
            log.info("downloading %s ...", url)
            with urllib.request.urlopen(url, timeout=120) as r:
                data = r.read()
            with tempfile.NamedTemporaryFile(suffix=".zip") as t:
                t.write(data)
                t.flush()
                with zipfile.ZipFile(t.name) as z:
                    for member in z.namelist():
                        if member.endswith("deno"):
                            with z.open(member) as src, open(candidate, "wb") as dst:
                                shutil.copyfileobj(src, dst)
                            break
                    else:
                        raise RuntimeError("deno binary not found in zip")
            os.chmod(candidate, 0o755)
            os.environ["PATH"] = bindir + os.pathsep + os.environ.get("PATH", "")
            log.info("deno installed at %s", candidate)
        except Exception as exc:                          # noqa: BLE001
            log.warning("deno bootstrap failed (%s); cold YouTube resolves "
                        "may be slow/time out", exc)
            return

    # yt-dlp only enables deno when it recognises the runtime; keep it current.
    try:
        subprocess.run([sys.executable, "-m", "pip", "install", "--no-cache-dir",
                        "-q", "-U", "yt-dlp"], timeout=600,
                       check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:                                    # noqa: BLE001
        pass

    # Report the bootstrap result so a diagnostics call can confirm the
    # container actually got a working JS runtime.
    try:
        ver = subprocess.run(["deno", "--version"], capture_output=True, text=True,
                             timeout=15)
        deno_ver = (ver.stdout or ver.stderr).strip().splitlines()[0]
    except Exception:                                    # noqa: BLE001
        deno_ver = None
    try:
        yv = subprocess.run(["yt-dlp", "--version"], capture_output=True,
                            text=True, timeout=15)
        yt = (yv.stdout or yv.stderr).strip().splitlines()[0]
    except Exception:                                    # noqa: BLE001
        yt = None
    try:
        state = getattr(_ensure_ytdlp_js_runtime, "_holder", None)
    except Exception:                                    # noqa: BLE001
        state = None
    _holder = {"deno": deno_ver, "yt_dlp": yt, "ts": time.time()}
    _ensure_ytdlp_js_runtime._holder = _holder
    log.info("js runtime report: %s", _holder)


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

    _log = logging.getLogger("nasmusic")
    threading.Thread(target=_ensure_ytdlp_js_runtime, args=(_log,),
                     daemon=True).start()

    # Clear stale innas cache from the previous server version (the suggest
    # index now walks playlist_dir too, so old "found: false" entries are wrong).
    try:
        state.db.execute(
            "DELETE FROM webcache WHERE key LIKE 'innas:%'")
    except Exception:
        pass

    # Prewarm the suggestion index in the background so the first keystroke
    # in the app is instant instead of walking the whole library live.
    try:
        from .httpd import Handler

        def warm():
            try:
                Handler._build_suggest_index(state)
            except Exception:                            # noqa: BLE001
                pass
        threading.Thread(target=warm, daemon=True).start()
    except Exception:                                     # noqa: BLE001
        pass

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

    print(f"gungan.fm server listening on "
          f"http://{config.host}:{config.port}/staging/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
