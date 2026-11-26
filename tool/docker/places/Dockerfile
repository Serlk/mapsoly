# Tiny image with pyosmium for tool/build_places.sh.
FROM python:3.13-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libexpat1 \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir osmium==4.0.2 shapely==2.1.1 numpy==2.3.1
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
