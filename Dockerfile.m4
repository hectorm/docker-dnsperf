m4_changequote([[, ]])

##################################################
## "build" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:20.04]], [[FROM docker.io/ubuntu:20.04]]) AS build
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& sed -i 's/^#\s*\(deb-src\s\)/\1/g' /etc/apt/sources.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		autoconf \
		automake \
		build-essential \
		ca-certificates \
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
		libprotobuf-c-dev \
		libssl-dev \
		libtool \
		libuv1-dev \
		libxml2-dev \
		pkgconf \
		tzdata

# Build CMake with "_FILE_OFFSET_BITS=64"
# (as a workaround for: https://gitlab.kitware.com/cmake/cmake/-/issues/20568)
WORKDIR /tmp/
RUN DEBIAN_FRONTEND=noninteractive apt-get build-dep -y cmake
RUN apt-get source cmake && mv ./cmake-*/ ./cmake/
WORKDIR /tmp/cmake/
RUN DEB_BUILD_PROFILES='stage1' \
	DEB_BUILD_OPTIONS='parallel=auto nocheck' \
	DEB_CFLAGS_SET='-D _FILE_OFFSET_BITS=64' \
	DEB_CXXFLAGS_SET='-D _FILE_OFFSET_BITS=64' \
	debuild -b -uc -us
RUN dpkg -i /tmp/cmake_*.deb /tmp/cmake-data_*.deb

# Build dnsperf and resperf
ARG DNSPERF_TREEISH=v2.7.1
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
ARG FLAMETHROWER_TREEISH=v0.11.0
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

##################################################
## "base" stage
##################################################

m4_ifdef([[CROSS_ARCH]], [[FROM docker.io/CROSS_ARCH/ubuntu:20.04]], [[FROM docker.io/ubuntu:20.04]]) AS base
m4_ifdef([[CROSS_QEMU]], [[COPY --from=docker.io/hectormolinero/qemu-user-static:latest CROSS_QEMU CROSS_QEMU]])

# Install system packages
RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		curl \
		gnuplot \
		knot-dnsutils \
		libbind9-161 \
		libcap2 \
		libck0 \
		libdns1109 \
		libfstrm0 \
		libgeoip1 \
		libgnutls30 \
		libisc1105 \
		libisccfg163 \
		libjson-c4 \
		libkrb5-3 \
		libldns2 \
		liblmdb0 \
		libprotobuf-c1 \
		libssl1.1 \
		libuv1 \
		libxml2 \
		tzdata \
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
RUN curl -Lo ./queryfile-example.gz "${QUERYFILE_EXAMPLE_URL:?}" \
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
