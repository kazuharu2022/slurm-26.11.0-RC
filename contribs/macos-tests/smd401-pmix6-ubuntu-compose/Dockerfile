FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        binutils \
        build-essential \
        bzip2 \
        ca-certificates \
        curl \
        file \
        libevent-dev \
        libhwloc-dev \
        libjson-c-dev \
        libjwt-dev \
        libmunge-dev \
        libtool \
        pkg-config \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY build.sh /usr/local/bin/smd401-build
RUN chmod 0755 /usr/local/bin/smd401-build

ENTRYPOINT ["/usr/local/bin/smd401-build"]
