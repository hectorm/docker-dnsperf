m4_changequote([[, ]])

##################################################
## "build" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:24.04]], [[FROM docker.io/ubuntu:24.04]]) AS build

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		autoconf \
		automake \
		build-essential \
		ca-certificates \
		cmake \
		devscripts \
		file \
		git \
		gnuplot \
		libcap-dev \
		libck-dev \
		libfstrm-dev \
		libgeoip-dev \
		libgnutls28-dev \
		libjson-c-dev \
		libkrb5-dev \
		libldns-dev \
		liblmdb-dev \
		libnghttp2-dev \
		libprotobuf-c-dev \
		libssl-dev \
		libtool \
		libuv1-dev \
		libxml2-dev \
		pkgconf \
		tzdata \
	&& rm -rf /var/lib/apt/lists/*

# Build dnsperf and resperf
ARG DNSPERF_TREEISH=v2.14.0
ARG DNSPERF_REMOTE=https://github.com/DNS-OARC/dnsperf.git
WORKDIR /tmp/dnsperf/
RUN git clone "${DNSPERF_REMOTE:?}" ./
RUN git checkout "${DNSPERF_TREEISH:?}"
RUN git submodule update --init --recursive
RUN ./autogen.sh
RUN ./configure --prefix=/usr
RUN make -j"$(nproc)"
RUN make install
RUN file /usr/bin/dnsperf
RUN file /usr/bin/resperf
RUN file /usr/bin/resperf-report

# Build flamethrower
ARG FLAMETHROWER_TREEISH=122d80f5f306131441c43b859699c637b602262c
ARG FLAMETHROWER_REMOTE=https://github.com/DNS-OARC/flamethrower.git
WORKDIR /tmp/flamethrower/
RUN git clone "${FLAMETHROWER_REMOTE:?}" ./
RUN git checkout "${FLAMETHROWER_TREEISH:?}"
RUN git submodule update --init --recursive
WORKDIR /tmp/flamethrower/build/
RUN cmake ../
RUN make -j"$(nproc)"
RUN mv ./flame /usr/bin/flame
RUN file /usr/bin/flame

# Download sample query data
ARG SAMPLE_QUERY_DATA_TREEISH=b7d520e380452fafcf6c3394bfb1ab4118cf783a
ARG SAMPLE_QUERY_DATA_REMOTE=https://github.com/DNS-OARC/sample-query-data.git
WORKDIR /tmp/sample-query-data/
RUN git clone "${SAMPLE_QUERY_DATA_REMOTE:?}" ./
RUN git checkout "${SAMPLE_QUERY_DATA_TREEISH:?}"
RUN git submodule update --init --recursive
RUN for f in ./queryfile-example-*.xz; do xz -dc "${f:?}" && rm -f "${f:?}"; done > ./queryfile-example

##################################################
## "base" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:24.04]], [[FROM docker.io/ubuntu:24.04]]) AS base

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		gnuplot \
		knot-dnsutils \
		libcap2 \
		libck0t64 \
		libfstrm0 \
		libgeoip1t64 \
		libgnutls30t64 \
		libjson-c5 \
		libkrb5-3 \
		libldns3t64 \
		liblmdb0 \
		libnghttp2-14 \
		libprotobuf-c1 \
		libssl3t64 \
		libuv1t64 \
		libxml2 \
		tzdata \
	&& rm -rf /var/lib/apt/lists/*

# Create unprivileged user
RUN userdel -rf "$(id -nu 1000)" && useradd -u 1000 -g 0 -s "$(command -v bash)" -m dnsperf

# Copy dnsperf, resperf and flame binaries
COPY --from=build --chown=root:root /usr/bin/dnsperf /usr/bin/dnsperf
COPY --from=build --chown=root:root /usr/bin/resperf /usr/bin/resperf
COPY --from=build --chown=root:root /usr/bin/resperf-report /usr/bin/resperf-report
COPY --from=build --chown=root:root /usr/bin/flame /usr/bin/flame
COPY --from=build --chown=root:root /tmp/sample-query-data/queryfile-example /home/dnsperf/queryfile-example

# Drop root privileges
USER dnsperf:root

WORKDIR /home/dnsperf/

##################################################
## "test" stage
##################################################

FROM base AS test

RUN dnsperf -l 2 -Q 1 -m udp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN dnsperf -l 2 -Q 1 -m tcp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN dnsperf -l 2 -Q 1 -m tls -p 853 -d ./queryfile-example -s 8.8.8.8
RUN resperf-report -c 2 -r 1 -m 1 -M udp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN resperf-report -c 2 -r 1 -m 1 -M tcp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN resperf-report -c 2 -r 1 -m 1 -M tls -p 853 -d ./queryfile-example -s 8.8.8.8
RUN flame -l 2 -Q 1 -c 1 -P udp    -p  53 8.8.8.8
RUN flame -l 2 -Q 1 -c 1 -P tcp    -p  53 8.8.8.8
RUN flame -l 2 -Q 1 -c 1 -P tcptls -p 853 8.8.8.8

##################################################
## "main" stage
##################################################

FROM base AS main

# Dummy instruction so BuildKit does not skip the test stage
RUN --mount=type=bind,from=test,source=/mnt/,target=/mnt/
