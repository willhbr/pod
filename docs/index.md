---
layout: page
---

Running any project can be as easy as:

```shell
$ pod run
```

By wrapping [Podman][podman] in a command-line interface that gets out of the way, you can easily containerise your development environment, removing dependency conflicts, and making managing a virtual environment unnecessary.

[podman]: http://podman.io/

`pod` simplifies the Podman CLI by defining targets to build and run in the `pods.yaml` file, so you never forget to include a flag. It still exposes the whole Podman CLI, so you don't have to learn a huge new set of options and how they map back to Podman. It can be as simple as:

```yaml
# in pods.yaml
containers:
  alpine-shell:
    name: pod-example
    image: docker.io/library/alpine:latest
    interactive: true
    args:
      - sh
# with the pod cli
$ pod run alpine-shell
```

`pod` scales up in complexity to add ports, mounts, and any other Podman feature[^not-all-features]. Once you've built the image you want to run in "production"[^not-actually], you can deploy it:

[^not-all-features]: Probably, I haven't tested them all.
[^not-actually]: `pod` is not intended for 100% robust production setups. Use Kubernetes instead. I am not an expert.

```shell
$ pod update -d
update: pods-website (arguments changed)
  podman
    run
    --detach=true
    --rm=true
    --mount=type=bind,src=.,dst=/src
-   --publish=4300:80
+   --publish=4301:80
    --name=pods-website
    --hostname=pods-website
    pods-website:latest
    --future
Container started at 2023-06-08 08:06:19 UTC (up 42m)
update? [y/N] y
```

`pod` will compare the configs of your running containers and the config in `pods.yaml`, and update anything that has changed.


## Installation

`pod` can be installed by building an image with all the necessary dependencies in it. You might need to change the base image, depending on your Linux flavour. 

```shell
$ git clone {{ site.urls.github }}.git
$ cd pod
$ ./install.sh ~/.local/bin
... installer will run and copy executable
```

## Quick Usage

```shell
$ pod init
# Run through guided setup
$ pod build
$ pod run
```

See [Getting Started](/examples/getting-started) for more detail, and [get more info on the config file](/examples/config).

## Script

`pod` can also be used to run simple scripts without setting up a whole project, see [pod script](/examples/script).
