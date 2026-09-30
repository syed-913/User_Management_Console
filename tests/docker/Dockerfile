# Disposable test image for UMC. One Dockerfile for every distro:
#   docker build --build-arg BASE=rockylinux/rockylinux:9 -f tests/docker/Dockerfile .
# The repository itself is NOT copied in; tests/run-in-docker.sh mounts it
# read-only at /src so the image never goes stale while you edit code.
ARG BASE=debian:12
FROM ${BASE}
COPY tests/docker/install-deps.sh /tmp/install-deps.sh
RUN sh /tmp/install-deps.sh && rm -f /tmp/install-deps.sh
WORKDIR /src
CMD ["bash", "tests/run.sh"]
