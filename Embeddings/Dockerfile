# The embedding sidecar. Built from this directory:
#
#   docker build -t dropwall-embeddings Embeddings/
#
# Weights are downloaded here, at build time, and the service runs with Hugging Face
# offline, so a boot never depends on huggingface.co being up or the repo still existing.
#
# The model is a build argument, pinned by commit. The default is Marqo FashionCLIP;
# "Choosing the model" in README.md has the alternatives and what switching costs:
#
#   docker build -t dropwall-embeddings \
#     --build-arg EMBEDDING_MODEL_REPO=Marqo/marqo-fashionSigLIP \
#     --build-arg EMBEDDING_MODEL_REVISION=c56244cc94f92419e8369fa71efdaf403b124ce8 Embeddings/
#
# Railway passes a service variable of the same name as a build argument, so setting both
# there selects the model for the next build.

ARG EMBEDDING_MODEL_REPO=Marqo/marqo-fashionCLIP
ARG EMBEDDING_MODEL_REVISION=44f4c655124ed71e90cbf528d82f508d69d8a81b

FROM python:3.12-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /venv
COPY requirements.txt /tmp/requirements.txt
# The CPU index first, so torch can only ever be the +cpu build; hashes pin everything.
RUN /venv/bin/pip install --require-hashes --only-binary=:all: \
      --index-url https://download.pytorch.org/whl/cpu \
      --extra-index-url https://pypi.org/simple \
      -r /tmp/requirements.txt

ARG EMBEDDING_MODEL_REPO
ARG EMBEDDING_MODEL_REVISION
COPY download_model.py /tmp/download_model.py
RUN /venv/bin/python /tmp/download_model.py /models/embedding \
      "$EMBEDDING_MODEL_REPO" "$EMBEDDING_MODEL_REVISION" \
    && rm -rf /models/embedding/.cache


FROM python:3.12-slim-bookworm

ARG EMBEDDING_MODEL_REPO
ARG EMBEDDING_MODEL_REVISION

RUN useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin embeddings
COPY --from=build /venv /venv
COPY --from=build /models /models
COPY embedding_service /app/embedding_service

# The model variables are kept in the environment so the service can check, at boot, that
# what the deployment asks for is what the image holds (`check_requested`).
ENV PATH=/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    EMBEDDING_MODEL_DIR=/models/embedding \
    EMBEDDING_MODEL_REPO=$EMBEDDING_MODEL_REPO \
    EMBEDDING_MODEL_REVISION=$EMBEDDING_MODEL_REVISION \
    PORT=8080

WORKDIR /app
USER embeddings
EXPOSE 8080
CMD ["python", "-m", "embedding_service"]
