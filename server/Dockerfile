FROM python:3.12-slim

# ffmpeg/ffprobe are required for verifying downloads and reading metadata.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg curl ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY nasmusic/ /app/nasmusic/
COPY pyproject.toml /app/pyproject.toml
RUN pip install --no-cache-dir -e .

EXPOSE 6680

# Override MUSIC_ROOT/STAGING_DIR/PLAYLIST_DIR via env when launching.
CMD ["python", "-m", "nasmusic", "--host", "0.0.0.0", "--port", "6680"]
