---
layout: page
---

_A helper utility for running containers_

## Installation

```shell
$ shards build pod --release
$ cp bin/pod ~/.local/bin
```

## Usage

```shell
$ pod init
# edit pods.yaml and Containerfile to taste
$ pod build example
$ pod run example
```

## `pods.yaml` Format

```yaml
# If no target is specified, use this one instead
defaults:
  build: website
  run: website

images:
  website:
    tag: willhbr.github.io:latest
    from: Containerfile.local

containers:
  website:
    name: willhbr.github.io
    image: willhbr.github.io:latest
    bind_mounts:
      .: /src
    ports:
      4000: 4000
    interactive: true
    autoremove: true
    run_args:
      userns: ""
```
