# syntax=docker/dockerfile:1.7
# Builder: static x86-64/musl Erlang/OTP + Elixir release, pinned by git tag.
#
# Runs NATIVELY on the Docker host's architecture (arm64 or x86-64); only the
# C parts of ERTS are cross-compiled for x86-64 with clang + an x86-64 Alpine
# sysroot. .beam files are architecture independent, so OTP's and Elixir's own
# libraries, and the mix release, are all produced by the native toolchain.
# This avoids running the BEAM under emulation (40+ min, flaky) on Mac hosts.
#
# Stages
#   sysroot   x86-64 Alpine root with musl, gcc runtime, static OpenSSL/zlib/zstd
#   otp-cross cross OTP tree for x86-64 (/opt/otp-x86), static beam.smp
#   otp-native native OTP (to run Elixir/mix); both built in parallel
#   elixir    Elixir compiled with the native OTP
#   release   mix release with include_erts = cross ERTS, plus static /init
#   out       scratch image containing /release, /init, /etc/ssl/cacert.pem

ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION} AS base
ARG ALPINE_VERSION
RUN apk add --no-cache \
      build-base clang lld llvm20 linux-headers perl git autoconf automake \
      openssl-dev ncurses-dev zlib-dev zstd-dev \
      ca-certificates curl file \
    && ln -sf /usr/lib/llvm20/bin/llvm-ar /usr/local/bin/llvm-ar \
    && ln -sf /usr/lib/llvm20/bin/llvm-ranlib /usr/local/bin/llvm-ranlib \
    && ln -sf /usr/lib/llvm20/bin/llvm-strip /usr/local/bin/llvm-strip
# x86-64 sysroot: musl + gcc/g++ (for crt*.o, libgcc.a, libstdc++.a) + static deps
RUN mkdir -p /sysroot && apk --arch x86_64 --root /sysroot --initdb \
      -X https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main \
      -X https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community \
      --allow-untrusted add --no-cache \
      musl-dev gcc g++ openssl-dev openssl-libs-static zlib-dev zlib-static \
      zstd-dev zstd-static ncurses-dev ncurses-static linux-headers \
    && ls /sysroot/usr/lib/libcrypto.a /sysroot/usr/lib/libstdc++.a /sysroot/usr/lib/crt1.o

# ---------------------------------------------------------------------------
# Apps not needed at build or run time. `tools` stays (Elixir's Makefile uses
# `erl -make`); it is pruned from the release later.
FROM base AS otp-src
ARG OTP_TAG=OTP-29.1.1
WORKDIR /src
RUN git clone --depth 1 --branch ${OTP_TAG} https://github.com/erlang/otp.git otp
WORKDIR /src/otp
# erts/configure hardcodes LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic". The
# trailing -Bdynamic makes lld link libc dynamically into a "-static" beam.smp,
# which then has a PT_DYNAMIC and segfaults before main. Everything is static
# here anyway, so drop the toggles.
RUN sed -i 's/LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic"/LIBZSTD="-lzstd"/' erts/configure erts/configure.ac
ENV OTP_WITHOUT="--without-javac --without-wx --without-odbc --without-debugger \
  --without-observer --without-et --without-megaco --without-jinterface \
  --without-cdv --without-dialyzer --without-diameter --without-eldap \
  --without-erl_docgen --without-ftp --without-mnesia --without-os_mon \
  --without-reltool --without-snmp --without-tftp --without-common_test \
  --without-edoc --without-ssh --without-runtime_tools --without-syntax_tools"

# ---- cross OTP for x86-64: native bootstrap, cross ERTS, all libs natively.
# `otp_build configure --xcomp-conf` is the only supported way to pass a cross
# config (CC/LIBS/feature answers live in the conf file).
FROM otp-src AS otp-cross
ARG JOBS=8
COPY builder/xcomp/erl-xcomp-x86_64-alpine-linux-musl.conf /xcomp.conf
RUN export ERL_TOP=$PWD && \
    ./otp_build configure --xcomp-conf=/xcomp.conf \
      --enable-static-nifs=yes --disable-dynamic-ssl-lib --with-ssl=/sysroot/usr \
      --enable-builtin-zlib $OTP_WITHOUT >/tmp/xconfigure.log 2>&1 || (tail -40 /tmp/xconfigure.log; exit 1) && \
    (grep -q '^crypto *:.*skip' /tmp/xconfigure.log && echo "crypto was skipped" && exit 1 || true) && \
    ./otp_build boot -a >/tmp/xboot.log 2>&1 || (tail -40 /tmp/xboot.log; exit 1) && \
    ./otp_build release -a /opt/otp-x86 >/tmp/xrelease.log 2>&1 || (tail -20 /tmp/xrelease.log; exit 1)
# Relink the two binaries we ship fully static (the default link is a PIE
# against musl's dynamic loader) and install them over the released ones.
RUN export ERL_TOP=$PWD && T=x86_64-alpine-linux-musl && \
    rm -f bin/$T/beam.jit bin/$T/beam.smp bin/$T/erl_child_setup && \
    make -j${JOBS} emulator TARGET=$T LDFLAGS="-static -fuse-ld=lld" >/tmp/relink.log 2>&1 || (tail -30 /tmp/relink.log; exit 1) && \
    ERTS=$(ls -d /opt/otp-x86/erts-*) && cp bin/$T/beam.smp bin/$T/erl_child_setup $ERTS/bin/ && \
    llvm-strip $ERTS/bin/beam.smp $ERTS/bin/erl_child_setup && \
    for f in $ERTS/bin/beam.smp $ERTS/bin/erl_child_setup; do \
      echo "== $f"; file "$f"; file "$f" | grep -q 'x86-64'; file "$f" | grep -q 'statically linked'; \
      ! readelf -l "$f" | grep -q INTERP; done && \
    basename $ERTS | sed s/erts-// > /opt/otp-x86/ERTS_VSN && cat /opt/otp-x86/ERTS_VSN
# Smoke-run the cross ERTS (qemu-user on arm64 hosts, native on x86-64 hosts).
COPY builder/cross-smoke.sh /cross-smoke.sh
RUN sh /cross-smoke.sh /opt/otp-x86

# ---- native OTP (same tag) so elixir/mix run at native speed.
FROM otp-src AS otp-native
ARG JOBS=8
RUN export ERL_TOP=$PWD CC=clang CXX=clang++ && \
    ./configure --prefix=/opt/otp $OTP_WITHOUT >/tmp/native-configure.log 2>&1 || (tail -30 /tmp/native-configure.log; exit 1) && \
    make -j${JOBS} >/tmp/native-make.log 2>&1 || (tail -30 /tmp/native-make.log; exit 1) && \
    make install >/tmp/native-install.log 2>&1
ENV PATH=/opt/otp/bin:$PATH
RUN erl -noshell -eval 'io:format("native otp ~s~n",[erlang:system_info(otp_release)]), halt().'

# ---------------------------------------------------------------------------
FROM otp-native AS elixir
ARG ELIXIR_TAG=v1.20.4
ARG JOBS=8
COPY --from=otp-cross /opt/otp-x86 /opt/otp-x86
WORKDIR /src
RUN git clone --depth 1 --branch ${ELIXIR_TAG} https://github.com/elixir-lang/elixir.git elixir
WORKDIR /src/elixir
RUN make -j${JOBS} compile && make install PREFIX=/opt/elixir
ENV PATH=/opt/elixir/bin:/opt/otp/bin:$PATH
RUN elixir --version

# ---------------------------------------------------------------------------
FROM elixir AS release
ENV MIX_ENV=prod LANG=C.UTF-8
# The release embeds the CROSS ERTS and takes OTP apps from the cross tree.
ENV UNIAPP_ERTS=/opt/otp-x86
WORKDIR /src/app
COPY app/mix.exs ./
COPY app/config config
COPY app/lib lib
RUN mix release --overwrite --path /out/release && \
    file /out/release/erts-*/bin/beam.smp | grep -q 'x86-64' && \
    ls /out/release/erts-*/bin/

# /init: tiny static C program that execs beam.smp directly (cross-compiled)
COPY init/init.c /src/init.c
RUN ERTS_VSN=$(cat /opt/otp-x86/ERTS_VSN) && echo "ERTS_VSN=$ERTS_VSN" && \
    clang --target=x86_64-alpine-linux-musl --sysroot=/sysroot -fuse-ld=lld \
      -O2 -Wall -static -s -DERTS_VSN="\"$ERTS_VSN\"" -o /out/init /src/init.c && \
    file /out/init | grep -q 'x86-64' && file /out/init | grep -q 'statically linked' && \
    echo "$ERTS_VSN" > /out/ERTS_VSN

# CA bundle for :ssl verify_peer
RUN mkdir -p /out/etc/ssl && cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/cacert.pem

FROM scratch AS out
COPY --from=release /out /
