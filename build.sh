#!/bin/sh

set -e

cd $HOME/$2

case "$1" in
  build)
    cargo doc --verbose --no-deps
    ;;
  clean)
    cargo clean --verbose
    ;;
esac
