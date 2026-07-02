# ビルドするタグ（例: Version-3.14.1）。CI からは --build-arg SC_VERSION=... で上書きされる
ARG SC_VERSION=Version-3.14.1

# ---- build stage (armv7) ----
ARG TARGETPLATFORM=linux/arm/v7
FROM --platform=$TARGETPLATFORM debian:bullseye AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake build-essential pkg-config \
    libjack-jackd2-dev libsndfile1-dev libasound2-dev \
    libavahi-client-dev libreadline-dev libfftw3-dev \
    libxt-dev libudev-dev ca-certificates \
    libboost-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
ARG SC_VERSION
RUN git clone --depth 1 --branch ${SC_VERSION} --recurse-submodules \
    https://github.com/supercollider/supercollider.git .

# get() の switch 後の assert(false); だけを、return付きに置換する
RUN perl -0777 -i -pe \
    's/(float get \(std::size_t index\) const\s*\{.*?)\bassert\(false\);/$1assert(false); return 0.f;/s' \
    external_libraries/nova-simd/vec/vec_neon.hpp

WORKDIR /src/build
RUN cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DSC_IDE=OFF -DSC_QT=OFF \
    -DSC_EL=OFF -DSC_VIM=OFF -DSC_ED=OFF \
    -DNATIVE=OFF \
    -DCMAKE_INSTALL_PREFIX=/opt/supercollider \
    && make -j2 \
    && make install

# ---- artifact stage (armv7): 展開済みディレクトリのまま抽出したい場合用 ----
# docker buildx build --target artifact -o type=local,dest=./out-armv7
FROM scratch AS artifact
COPY --from=builder /opt/supercollider /opt/supercollider

# ---- package stage (armv7): tar.gz を Docker 側で作成 ----
# --platform=$BUILDPLATFORM でビルドホスト側のネイティブアーキテクチャで実行し、
# tar/gzip のためだけに QEMU エミュレーションを使わないようにする
FROM --platform=$BUILDPLATFORM debian:bullseye-slim AS package
ARG SC_VERSION
COPY --from=builder /opt/supercollider /opt/supercollider
RUN tar czf "/supercollider-${SC_VERSION}-armv7.tar.gz" -C /opt supercollider

# ---- release stage (armv7): tar.gz だけを抽出 ----
# docker buildx build --target release -o type=local,dest=./dist-armv7
FROM scratch AS release
COPY --from=package /supercollider-*.tar.gz /

# ---- runtime stage (armv7) ----
FROM --platform=linux/arm/v7 debian:bullseye-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsndfile1 libasound2 libavahi-client3 libfftw3-single3 \
    libjack-jackd2-0 jackd2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/supercollider /opt/supercollider
ENV PATH="/opt/supercollider/bin:${PATH}"

# scsynth をデフォルト起動（必要に応じて変更）
ENTRYPOINT ["scsynth"]
CMD ["-u", "57110"]
