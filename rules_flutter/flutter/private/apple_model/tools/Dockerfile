# Spike T17a: the container the Apple pin step runs in. Not for merge.
# The official Ruby image by digest, CocoaPods and every gem under it by Gemfile.lock. git and curl
# are what CocoaPods' downloader shells out to; build-essential compiles the gems' C parts.
FROM ruby@sha256:b5a2eaadcdde89e3ccbe9113ba23c9e890a6381f4e928bc76e3c91423a325452
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates build-essential unzip xz-utils bzip2 rsync file \
 && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock /pin-gems/
RUN BUNDLE_GEMFILE=/pin-gems/Gemfile BUNDLE_FROZEN=true bundle install \
 && gem list --local > /gems.txt
# Every Ruby process in the container (`pod`, `ruby pin.rb`) loads the locked gems and no other.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 COCOAPODS_DISABLE_STATS=true \
    BUNDLE_GEMFILE=/pin-gems/Gemfile BUNDLE_FROZEN=true RUBYOPT=-rbundler/setup
