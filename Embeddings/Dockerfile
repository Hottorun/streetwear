# The embedding sidecar. Built from this directory:
#
#   docker build -t dropwall-embeddings Embeddings/
#
# Weights are downloaded here, at build time, and the service runs with Hugging Face
# offline, so a boot never depends on huggingface.co being up or the repo still existing.

FROM python:3.12-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /venv
COPY requirements.txt /tmp/requirements.txt
# The CPU index first, so torch can only ever be the +cpu build; hashes pin everything.
RUN /venv/bin/pip install --require-hashes --only-binary=:all: \
      --index-url https://download.pytorch.org/whl/cpu \
      --extra-index-url https://pypi.org/simple \
      -r /tmp/requirements.txt

COPY download_model.py /tmp/download_model.py
RUN /venv/bin/python /tmp/download_model.py /models/fashionsiglip \
    && rm -rf /models/fashionsiglip/.cache


FROM python:3.12-slim-bookworm

RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin embeddings
COPY --from=build /venv /venv
COPY --from=build /models /models
COPY embedding_service /app/embedding_service

ENV PATH=/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    EMBEDDING_MODEL_DIR=/models/fashionsiglip \
    PORT=8080

WORKDIR /app
USER embeddings
EXPOSE 8080
CMD ["python", "-m", "embedding_service"]
