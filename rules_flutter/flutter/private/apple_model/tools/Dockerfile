# Spike T17a: the container the Apple pin step runs in. Not for merge.
# The official Ruby image by digest, CocoaPods by version. git and curl are what
# CocoaPods' downloader shells out to; build-essential compiles the gems' C parts.
FROM ruby@sha256:b5a2eaadcdde89e3ccbe9113ba23c9e890a6381f4e928bc76e3c91423a325452
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates build-essential unzip xz-utils bzip2 rsync file \
 && rm -rf /var/lib/apt/lists/*
RUN gem install cocoapods -v 1.16.2 --no-document \
 && gem list --local > /gems.txt
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 COCOAPODS_DISABLE_STATS=true
