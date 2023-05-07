#!/bin/bash

shards run pod-compost -- "$@"

# podman run \
# 	--rm \
# 	--tty \
# 	--init \
# 	--interactive \
# 	--network host \
# 	--volume `pwd`:/src \
# 	--workdir /src \
#   --name pod-compost \
# 	crystallang/crystal:latest \
# 	shards run pod-compost -- "$@"
