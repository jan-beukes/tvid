#!/bin/sh

set -xe

odin build . -extra-linker-flags:'-static'
