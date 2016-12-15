FROM ubuntu:16.04

# One dependency per line in alphabetical order.
# This should help avoiding duplicates and make the file easier to update.
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    gcovr \
    git \
    g++-4.9 \
    libprocps4-dev \
    libssl-dev \
    pandoc \
    python-cheetah \
    python-pip \
    pkg-config \
    ruby \
    ruby-dev \
    s3cmd \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN pip install diff_cover

# Setup coverity
ARG TOKEN

RUN cd /opt \
    && wget https://scan.coverity.com/download/linux64 --post-data "token=${TOKEN}&project=realm%2Frealm-core" -O coverity_tool.tgz \
    && tar zxf coverity_tool.tgz \
    && rm coverity_tool.tgz \
    && mv cov-analysis-linux64-* cov-analysis-linux64

ENV PATH "$PATH:/opt/cov-analysis-linux64/bin"

VOLUME /source
VOLUME /out

WORKDIR /source