FROM ubuntu:24.04

ARG LIBB64_VERSION=1.2-5
ARG LIBHTTP_PARSER_VERSION=2.9.4-6build1
ARG LIBJANSSON_VERSION=2.14-2build2
ARG LIBJWT_VERSION=1.17.0-2build2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        file \
        "libb64-0d=${LIBB64_VERSION}" \
        "libhttp-parser2.9=${LIBHTTP_PARSER_VERSION}" \
        "libjansson4=${LIBJANSSON_VERSION}" \
        "libjwt2=${LIBJWT_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

COPY build.sh /usr/local/bin/smd405-runtime-build
RUN chmod 0755 /usr/local/bin/smd405-runtime-build

ENTRYPOINT ["/usr/local/bin/smd405-runtime-build"]
