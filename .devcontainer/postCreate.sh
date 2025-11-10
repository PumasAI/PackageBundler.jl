#!/usr/bin/env bash

set -e -o pipefail -u -x

additional_archs=()
if [[ $(uname -m) == x86_64 ]]; then
    additional_archs+=(i386)
fi

for arch in "${additional_archs[@]}"; do
    sudo dpkg --add-architecture "$arch"
done

sudo apt-get update

for arch in "${additional_archs[@]}"; do
    sudo apt-get --yes install --no-install-recommends libc6:$arch
done
