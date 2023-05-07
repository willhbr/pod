# Pod

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
    image: willhbr.github.io
    run-args:
      userns: ""
      mount: type=bind,src=.,dst=/src
      publish: 4000:4000
      rm: true
      interactive: true
      tty: true
```
