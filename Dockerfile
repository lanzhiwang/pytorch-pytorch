# syntax=docker/dockerfile:1

# NOTE: Building this image require's docker version >= 23.0.
#
# For reference:
# - https://docs.docker.com/build/dockerfile/frontend/#stable-channel

ARG BASE_IMAGE=ubuntu:24.04

FROM ${BASE_IMAGE} as dev-base
# [dev-base 1/5] FROM docker.io/library/ubuntu:24.04@sha256:186072bba1b2f436cbb91ef2567abca677337cfc786c86e107d25b7072feef0c

RUN set -x && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        curl \
        git \
        libjpeg-dev \
        libpng-dev \
        python3 \
        python3-pip \
        python-is-python3 \
        python3-dev && \
    rm -rf /var/lib/apt/lists/*
# [dev-base 2/5] RUN
# set -x &&
# apt-get update &&
# DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential ca-certificates ccache cmake curl git libjpeg-dev libpng-dev python3 python3-pip python-is-python3 python3-dev &&
# rm -rf /var/lib/apt/lists/*

# Remove PEP 668 restriction (safe in containers)
RUN rm -f /usr/lib/python*/EXTERNALLY-MANAGED
# [dev-base 3/5] RUN rm -f /usr/lib/python*/EXTERNALLY-MANAGED

RUN /usr/sbin/update-ccache-symlinks
# [dev-base 4/5] RUN /usr/sbin/update-ccache-symlinks

RUN mkdir /opt/ccache && ccache --set-config=cache_dir=/opt/ccache
# [dev-base 5/5] RUN mkdir /opt/ccache && ccache --set-config=cache_dir=/opt/ccache

FROM dev-base as python-deps

COPY requirements.txt requirements-build.txt .
# [python-deps 1/2] COPY requirements.txt requirements-build.txt .

# Install Python packages to system Python
RUN pip3 install --upgrade --ignore-installed pip setuptools wheel && \
    pip3 install cmake pyyaml numpy ipython -r requirements.txt
# [python-deps 2/2] RUN
# pip3 install --upgrade --ignore-installed pip setuptools wheel &&
# pip3 install cmake pyyaml numpy ipython -r requirements.txt

FROM dev-base as submodule-update

WORKDIR /opt/pytorch
# [submodule-update 1/3] WORKDIR /opt/pytorch

COPY . .
# [submodule-update 2/3] COPY . .

RUN git submodule update --init --recursive
# [submodule-update 3/3] RUN git submodule update --init --recursive

FROM python-deps as pytorch-installs
ARG CUDA_PATH=cu121
ARG INSTALL_CHANNEL=whl/nightly
# Automatically set by buildx
ARG TARGETPLATFORM

# INSTALL_CHANNEL whl - release, whl/nightly - nightly, whl/test - test channels
RUN set -x && case ${TARGETPLATFORM} in \
         "linux/arm64")  pip3 install --extra-index-url https://download.pytorch.org/whl/cpu/ torch torchvision torchaudio ;; \
         *)              pip3 install --index-url https://download.pytorch.org/${INSTALL_CHANNEL}/${CUDA_PATH#.}/ torch torchvision torchaudio ;; \
    esac
# [pytorch-installs 1/3] RUN
# set -x &&
# case linux/amd64 in
#     "linux/arm64") pip3 install --extra-index-url https://download.pytorch.org/whl/cpu/ torch torchvision torchaudio ;;
#     *)             pip3 install --index-url https://download.pytorch.org/whl/cu121/ torch torchvision torchaudio ;;
# esac

RUN pip3 install torchelastic
# [pytorch-installs 2/3] RUN pip3 install torchelastic

RUN set -x && IS_CUDA=$(python3 -c 'import torch ; print(torch.cuda._is_compiled())'); \
    echo "Is torch compiled with cuda: ${IS_CUDA}"; \
    if test "${IS_CUDA}" != "True" -a ! -z "${CUDA_VERSION}"; then \
        exit 1; \
    fi
# [pytorch-installs 3/3] RUN
# set -x &&
# IS_CUDA=$(python3 -c 'import torch ; print(torch.cuda._is_compiled())');
# echo "Is torch compiled with cuda: ${IS_CUDA}";
# if test "${IS_CUDA}" != "True" -a ! -z "${CUDA_VERSION}"; then
#     exit 1;
# fi
# python3 -c import torch ; print(torch.cuda._is_compiled())
# IS_CUDA=True
# echo Is torch compiled with cuda: True
# test True != True -a ! -z

FROM ${BASE_IMAGE} as official

ARG PYTORCH_VERSION
ARG TRITON_VERSION
ARG TARGETPLATFORM
ARG CUDA_VERSION

LABEL com.nvidia.volumes.needed="nvidia_driver"

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        libjpeg-dev \
        libpng-dev \
        python-is-python3 \
        python3 \
        python3-dev \
        python3-pip \
        && rm -rf /var/lib/apt/lists/*
# [official 2/6] RUN
# apt-get update &&
# DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates libjpeg-dev libpng-dev python-is-python3 python3 python3-dev python3-pip &&
# rm -rf /var/lib/apt/lists/*

# Copy Python packages from pytorch-installs stage
COPY --from=pytorch-installs /usr/local/lib/python3.12 /usr/local/lib/python3.12
# [official 3/6] COPY --from=pytorch-installs /usr/local/lib/python3.12 /usr/local/lib/python3.12

COPY --from=pytorch-installs /usr/local/bin /usr/local/bin
# [official 4/6] COPY --from=pytorch-installs /usr/local/bin /usr/local/bin

RUN if test -n "${CUDA_VERSION}" -a "${TARGETPLATFORM}" != "linux/arm64"; then \
        apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc && \
        rm -rf /var/lib/apt/lists/*; \
    fi
# [official 5/6] RUN
# if test -n "12.1.1" -a "linux/amd64" != "linux/arm64"; then
#     apt-get update -qq &&
#     DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc &&
#     rm -rf /var/lib/apt/lists/*;
# fi

ENV NVIDIA_VISIBLE_DEVICES all
ENV NVIDIA_DRIVER_CAPABILITIES compute,utility
ENV LD_LIBRARY_PATH /usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV PATH /usr/local/nvidia/bin:/usr/local/cuda/bin:$PATH
ENV PYTORCH_VERSION ${PYTORCH_VERSION}

WORKDIR /workspace
# [official 6/6] WORKDIR /workspace

FROM official as dev
ARG CUDA_VERSION
ARG BUILD_TYPE

# Install CUDA toolkit for devel images
# Only runs when building devel-image target (BUILD_TYPE != official)
RUN set -x && if [ "${BUILD_TYPE}" = "dev" ] && [ -n "${CUDA_VERSION}" ]; then \
    apt-get update && apt-get install -y --no-install-recommends \
        wget gnupg2 ca-certificates && \
    # Add NVIDIA repository
    NVARCH=$(uname -m | sed 's/x86_64/x86_64/' | sed 's/aarch64/sbsa/') && \
    wget -qO - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/${NVARCH}/3bf863cc.pub | apt-key add - && \
    echo "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/${NVARCH} /" > /etc/apt/sources.list.d/cuda.list && \
    # Install CUDA toolkit
    CUDA_PKG_VERSION=$(echo ${CUDA_VERSION} | cut -d'.' -f1,2 | tr '.' '-') && \
    apt-get update && apt-get install -y --no-install-recommends \
        cuda-toolkit-${CUDA_PKG_VERSION} && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    # Configure LD
    echo "/usr/local/cuda/lib64" >> /etc/ld.so.conf.d/cuda.conf && \
    ldconfig; \
fi
# [dev 1/4] RUN
# set -x &&
# if [ "dev" = "dev" ] && [ -n "12.1.1" ]; then
#     apt-get update && apt-get install -y --no-install-recommends wget gnupg2 ca-certificates &&
#     NVARCH=$(uname -m | sed 's/x86_64/x86_64/' | sed 's/aarch64/sbsa/') &&
#     wget -qO - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/${NVARCH}/3bf863cc.pub | apt-key add - &&
#     echo "deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/${NVARCH} /" > /etc/apt/sources.list.d/cuda.list &&
#     CUDA_PKG_VERSION=$(echo 12.1.1 | cut -d'.' -f1,2 | tr '.' '-') &&
#     apt-get update && apt-get install -y --no-install-recommends cuda-toolkit-${CUDA_PKG_VERSION} &&
#     apt-get clean &&
#     rm -rf /var/lib/apt/lists/* &&
#     echo "/usr/local/cuda/lib64" >> /etc/ld.so.conf.d/cuda.conf &&
#     ldconfig;
# fi
# uname -m
# sed s/aarch64/sbsa/
# sed s/x86_64/x86_64/
# NVARCH=x86_64
# wget -qO - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub | apt-key add -
# echo deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64 /
# echo 12.1.1 | cut -d. -f1,2 |  tr . -
# CUDA_PKG_VERSION=12-1
# apt-get install -y --no-install-recommends cuda-toolkit-12-1

# Set CUDA environment (always set, needed even if CUDA already in base)
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
ENV CUDA_HOME=/usr/local/cuda

# Should override the already installed version from the official-image stage
COPY --from=python-deps /usr/local/lib/python3.12 /usr/local/lib/python3.12
# [dev 2/4] COPY --from=python-deps /usr/local/lib/python3.12 /usr/local/lib/python3.12

COPY --from=python-deps /usr/local/bin /usr/local/bin
# [dev 3/4] COPY --from=python-deps /usr/local/bin /usr/local/bin

COPY --from=submodule-update /opt/pytorch /opt/pytorch
# [dev 4/4] COPY --from=submodule-update /opt/pytorch /opt/pytorch
