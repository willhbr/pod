#!/bin/bash

set -ex

output="${1}"

if [ -z "$output" ]; then
  echo 'Usage: ./install.sh <output folder>'
fi

echo 'Building pod image...'
podman build --tag=pod:installer --file=Containerfile.prod .

echo "Copying file to $1"
podman run --tty=true --interactive=true --rm=true \
  --mount=type=bind,src=.,dst=/src --mount=type=bind,src="$output",dst=/output \
  --name=pod-install localhost/pod:installer

echo "pod installed to $output: "

if ! which pod; then
  echo 'pod not installed to $PATH; move it into $PATH to use it'
  exit 1
fi
