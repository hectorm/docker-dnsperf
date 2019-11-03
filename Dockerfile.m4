m4_changequote([[, ]])

##################################################
## "build" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/debian:10]], [[FROM docker.io/debian:10]]) AS build
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		autoconf \
		automake \
		build-essential \
		ca-certificates \
		cmake \
		file \
		git \
		gnuplot \
		libbind-dev \
		libcap-dev \
		libfstrm-dev \
		libgeoip-dev \
		libgnutls28-dev \
		libjson-c-dev \
		libkrb5-dev \
		libldns-dev \
		liblmdb-dev \
		libprotobuf-c-dev \
		libssl-dev \
		libtool \
		libuv1-dev \
		libxml2-dev \
		pkgconf \
		tzdata

# Build dnsperf and resperf
ARG DNSPERF_TREEISH=v2.3.2
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
ARG FLAMETHROWER_TREEISH=v0.10
ARG FLAMETHROWER_REMOTE=https://github.com/DNS-OARC/flamethrower.git
WORKDIR /tmp/flamethrower/
RUN git clone "${FLAMETHROWER_REMOTE:?}" ./
RUN git checkout "${FLAMETHROWER_TREEISH:?}"
RUN git submodule update --init --recursive
WORKDIR /tmp/flamethrower/build/
RUN cmake ../
RUN make -j"$(nproc)"
RUN mv ./flame /usr/bin/flame
RUN file /usr/bin/flamethrower

##################################################
## "base" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/debian:10]], [[FROM docker.io/debian:10]]) AS base
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		gnuplot \
		knot-dnsutils \
		libbind9-161 \
		libcap2 \
		libdns1104 \
		libfstrm0 \
		libgeoip1 \
		libgnutls30 \
		libisc1100 \
		libisccfg163 \
		libjson-c3 \
		libkrb5-3 \
		libldns2 \
		liblmdb0 \
		libprotobuf-c1 \
		libssl1.1 \
		libuv1 \
		libxml2 \
		tzdata \
		wget \
	&& rm -rf /var/lib/apt/lists/*

# Create users and groups
ARG DNSPERF_USER_UID=1000
ARG DNSPERF_USER_GID=1000
RUN groupadd \
		--gid "${DNSPERF_USER_GID:?}" \
		dnsperf
RUN useradd \
		--uid "${DNSPERF_USER_UID:?}" \
		--gid "${DNSPERF_USER_GID:?}" \
		--shell "$(command -v bash)" \
		--home-dir /home/dnsperf/ \
		--create-home \
		dnsperf

# Copy dnsperf, resperf and flame binaries
COPY --from=build --chown=root:root /usr/bin/dnsperf /usr/bin/dnsperf
COPY --from=build --chown=root:root /usr/bin/resperf /usr/bin/resperf
COPY --from=build --chown=root:root /usr/bin/resperf-report /usr/bin/resperf-report
COPY --from=build --chown=root:root /usr/bin/flame /usr/bin/flame

# Switch to unprivileged user
USER dnsperf:dnsperf
WORKDIR /home/dnsperf/

# Download sample query file
ARG QUERYFILE_EXAMPLE_URL=https://www.dns-oarc.net/files/dnsperf/data/queryfile-example-current.gz
ARG QUERYFILE_EXAMPLE_CHECKSUM=4102f3197d5cc762ad51ee95f74b0330ddf60e922c9124f037f092f72774e603
RUN wget -O ./queryfile-example.gz "${QUERYFILE_EXAMPLE_URL:?}" \
	&& printf '%s' "${QUERYFILE_EXAMPLE_CHECKSUM:?}  ./queryfile-example.gz" | sha256sum -c \
	&& gunzip ./queryfile-example.gz

##################################################
## "test" stage
##################################################

FROM base AS test
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

RUN dnsperf -l 5 -Q 5 -m udp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN dnsperf -l 5 -Q 5 -m tcp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN dnsperf -l 5 -Q 5 -m tls -p 853 -d ./queryfile-example -s 8.8.8.8
RUN resperf-report -c 5 -r 5 -m 5 -M udp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN resperf-report -c 5 -r 5 -m 5 -M tcp -p  53 -d ./queryfile-example -s 8.8.8.8
RUN resperf-report -c 5 -r 5 -m 5 -M tls -p 853 -d ./queryfile-example -s 8.8.8.8
RUN flame -l 5 -Q 5 -P udp    -p  53 8.8.8.8
RUN flame -l 5 -Q 5 -P tcp    -p  53 8.8.8.8
RUN flame -l 5 -Q 5 -P tcptls -p 853 8.8.8.8

##################################################
## "dnsperf" stage
##################################################

FROM base AS dnsperf
