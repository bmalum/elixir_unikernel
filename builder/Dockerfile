# syntax=docker/dockerfile:1.7
# Builder: static-musl Erlang/OTP + Elixir, pinned by git tag.
# Everything in here runs on x86_64 Alpine. The output of interest is
# /out/release (the mix release with embedded ERTS) and /out/init.

ARG ALPINE_VERSION=3.22
FROM --platform=linux/amd64 alpine:${ALPINE_VERSION} AS otp

ARG OTP_TAG=OTP-29.1.1
ARG JOBS=8

RUN apk add --no-cache \
      build-base clang lld linux-headers perl git autoconf automake \
      openssl-dev openssl-libs-static \
      ncurses-dev ncurses-static \
      zlib-dev zlib-static \
      zstd-dev zstd-static \
      lld ca-certificates curl

WORKDIR /src
RUN git clone --depth 1 --branch ${OTP_TAG} https://github.com/erlang/otp.git otp

WORKDIR /src/otp
# Fully static beam.smp:
#  - enable-static-nifs=yes  : crypto/asn1 NIF archives linked into beam.smp (no dlopen)
#  - LIBS                    : their external deps, static (OpenSSL 3, zlib, zstd)
#  - disable-dynamic-ssl-lib : crypto links libcrypto.a
#  - -static is passed to make, not configure: configure's DED (shared-object)
#    conftests fail with "-static -shared".
#  - CC=clang + lld: Alpine's gcc (cc1, collect2) segfaults intermittently
#    when emulated under Rosetta (Mac hosts); clang/lld are stable everywhere.
#  - without-* : drop everything the MVP does not need
ENV CC=clang CXX=clang++
# erts/configure hardcodes LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic". The trailing
# -Bdynamic makes the linker pull libc/libstdc++ dynamically into the "-static"
# beam.smp (lld does this silently; bfd errors out), and the result segfaults at
# start. Everything is static here anyway, so drop the toggles.
RUN sed -i 's/LIBZSTD="-Wl,-Bstatic -lzstd -Wl,-Bdynamic"/LIBZSTD="-lzstd"/' erts/configure erts/configure.ac && \
    grep -n 'LIBZSTD="-lzstd"' erts/configure
RUN export ERL_TOP=$PWD && \
    CFLAGS="-O2 -g0" \
    LDFLAGS="-fuse-ld=lld" \
    LIBS="-lcrypto -lssl -lz -lzstd" \
    ./configure \
      --prefix=/opt/otp \
      --enable-static-nifs=yes \
      --disable-dynamic-ssl-lib \
      --with-ssl=/usr \
      --enable-builtin-zlib \
      --without-javac --without-wx --without-odbc --without-debugger \
      --without-observer --without-et --without-megaco --without-jinterface \
      --without-cdv --without-dialyzer --without-diameter --without-eldap \
      --without-erl_docgen --without-ftp --without-mnesia --without-os_mon \
      --without-reltool --without-snmp --without-tftp \
      --without-common_test --without-edoc --without-ssh \
      --without-runtime_tools --without-tools --without-syntax_tools \
    && STATIC='LDFLAGS=-static -fuse-ld=lld' \
    && (make -j${JOBS} depend erl_interface emulator "$STATIC" || make -j1 depend erl_interface emulator "$STATIC") \
    && (make -j${JOBS} || make -j2 || make -j1) \
    && make install
# - `-static` is applied only to the C targets (erl_interface, emulator =
#   beam.smp + erl_child_setup + erts/etc programs). Passing it to the whole
#   build also hits the dynamic NIF .so targets (asn1rt_nif.so) which cannot
#   link -static -shared. The .so files are unused (static NIFs are linked in).
# - The retries exist for Mac hosts: under Rosetta the freshly built JIT
#   emulator occasionally segfaults while compiling OTP's own Erlang sources.
#   make is incremental, so a retry only redoes the failed module.

# Sanity: every ELF in erts bin must be static
RUN set -e; for f in /opt/otp/lib/erlang/erts-*/bin/beam.smp /opt/otp/lib/erlang/erts-*/bin/erl_child_setup; do \
      echo "== $f"; file "$f"; file "$f" | grep -q 'statically linked'; \
      ! (nm "$f" | grep -qE ' U (dlopen|dlsym)$') ; done

# ---------------------------------------------------------------------------
FROM otp AS elixir
ARG ELIXIR_TAG=v1.20.4
ENV PATH=/opt/otp/bin:$PATH
WORKDIR /src
RUN git clone --depth 1 --branch ${ELIXIR_TAG} https://github.com/elixir-lang/elixir.git elixir
WORKDIR /src/elixir
# Elixir's own build runs the (static, JIT) beam.smp. On Rosetta hosts that can
# segfault sporadically; the build is incremental, so retry.
RUN (make -j${JOBS} compile || make -j2 compile || make -j1 compile) && make install PREFIX=/opt/elixir
ENV PATH=/opt/elixir/bin:/opt/otp/bin:$PATH
RUN erl -noshell -eval 'io:format("~s~n",[erlang:system_info(otp_release)]), halt().' && elixir --version

# ---------------------------------------------------------------------------
FROM elixir AS release
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /src/app
COPY app/mix.exs ./
COPY app/config config
COPY app/lib lib
# No deps, so no hex/network needed. Retry for the same Rosetta reason as above.
RUN mix release --overwrite --path /out/release || mix release --overwrite --path /out/release

# /init: tiny static C program that execs beam.smp directly
COPY init/init.c /src/init.c
RUN ERTS_VSN=$(basename /out/release/erts-* | sed 's/^erts-//') && echo "ERTS_VSN=$ERTS_VSN" && \
    clang -O2 -Wall -static -fuse-ld=lld -s -DERTS_VSN="\"$ERTS_VSN\"" -o /out/init /src/init.c && \
    file /out/init | grep -q 'statically linked' && echo "$ERTS_VSN" > /out/ERTS_VSN

# CA bundle for :ssl verify
RUN mkdir -p /out/etc/ssl && cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/cacert.pem

FROM scratch AS out
COPY --from=release /out /
