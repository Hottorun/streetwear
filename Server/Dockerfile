# Build context is the REPO ROOT, not Server/ — StreetwServer depends on the root
# package by path, so both trees must be in the image:
#
#   docker build -f Server/Dockerfile -t streetw-server .
#
# On Railway this is configured by railway.json at the repo root, which pins the
# Dockerfile builder. Without it Railway falls back to its Railpack autodetector,
# which has no Swift provider and fails with "could not determine how to build the app".

# ---------- build ----------
FROM swift:6.0-noble AS build

WORKDIR /build

# The whole source tree is copied before building: SwiftPM validates that every declared
# target directory exists when it loads the package graph, including the path dependency,
# so resolving against manifests alone doesn't work here.
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Server/Package.swift Server/Package.resolved ./Server/
COPY Server/Sources ./Server/Sources

WORKDIR /build/Server
RUN swift build -c release --product StreetwServer --static-swift-stdlib

RUN mkdir -p /staging \
 && cp "$(swift build -c release --show-bin-path)/StreetwServer" /staging/ \
 # Foundation looks for these resource bundles at runtime.
 && find -L "$(swift build -c release --show-bin-path)/" -regex '.*\.resources$' -exec cp -Ra {} /staging/ \; \
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
# Host and port come from the environment (configure.swift reads PORT), because hosting
# platforms assign the port at runtime rather than letting the app pick one.
ENTRYPOINT ["/app/StreetwServer"]
CMD ["serve", "--env", "production"]
