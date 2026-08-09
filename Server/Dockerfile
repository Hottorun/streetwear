# Build context is the REPO ROOT, not Server/ — StreetwServer depends on the root
# package by path, so both must be present:
#
#   docker build -f Server/Dockerfile -t streetw-server .
#
# Railway: set the Dockerfile path to Server/Dockerfile and leave the root as context.

# ---------- build ----------
FROM swift:6.0-noble AS build

WORKDIR /build

# Resolve dependencies first so this layer caches across source-only changes.
COPY Package.swift Package.resolved* ./
COPY Server/Package.swift Server/Package.resolved* ./Server/
RUN cd Server && swift package resolve

COPY Sources ./Sources
COPY Server/Sources ./Server/Sources

RUN cd Server && swift build -c release --product StreetwServer \
      -Xswiftc -g \
      --static-swift-stdlib

RUN mkdir -p /staging \
 && cp "$(cd Server && swift build -c release --show-bin-path)/StreetwServer" /staging/ \
 # Bundle the ICU/resource files Foundation needs at runtime.
 && find -L "$(cd Server && swift build -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} /staging/ \; \
 && ([ -d /usr/libexec/swift/linux/swift-backtrace-static ] \
      && cp -R /usr/libexec/swift/linux/swift-backtrace-static /staging/ || true)

# ---------- run ----------
FROM ubuntu:noble

RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
      ca-certificates tzdata libcurl4 libxml2 \
 && rm -rf /var/lib/apt/lists/*

# Never run as root.
RUN useradd --user-group --create-home --home-dir /app --shell /usr/sbin/nologin streetw
WORKDIR /app

COPY --from=build --chown=streetw:streetw /staging /app

ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=/app/swift-backtrace-static
USER streetw:streetw

EXPOSE 8080
ENTRYPOINT ["/app/StreetwServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
