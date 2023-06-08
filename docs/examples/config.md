---
title: "pods.yaml format"
layout: page
---

# pods.yaml format

```yaml
defaults:
  build: my-image
  run: my-container
  update: my-container

# groups let you build, run, or update multiple targets in one command
groups:
  images:
    - my-image
    - my-other-image

# these are the images that can be built using `pod build`
# you can still reference other images in the `containers` section`
images:
  my-image:
    # this tag will be applied to the image whenever it gets built
    tag: my-image:latest
    # this is the containerfile to build from
    from: Containerfile
    # the build context is resolved relative to the directory of the config file
    # it defaults to the current directory
    context: .
    # flags that will be passed to `podman` before the `build` subcommand
    podman_flags:
      hooks-dir: /tmp/hooks
    # flags that will be passed to the `build` subcommand
    # some of these will be overridden or conflict with top-level options
    build_flags:
      cert-dir: /tmp/certs
    # sets build args to make available to the Containerfile
    build_args:
      ARG: value
    # build this image on a remote host using podman-remote
    remote: my-remote-host

containers:
  my-container:
    name: my-container-dev
    image: my-image:latest
    podman_flags:
      # same as for images, passed before `run`
    run_flags:
      # passed after `run`
    environment:
      LANG: en_US.UTF-8
    # overrides --interactive and --tty or --detach
    interactive: true
    # overrides --rm
    autoremove: true
    # translated to --mount arguments
    bind_mounts:
      /tmp/logs: /logs
    # translated to --mount arguments
    volumes:
      storage: /data
    # translated to --publish arguments
    ports:
      5000: 80
    # run this container on a different machine using podman-remote 
    remote: my-server
    # flags passed to the binary in the form `--$KEY=$VALUE`
    # not all applications accept this exact format
    # (eg they don't like explicit --option=true)
    # in that case you can use `args:` to specify an exact string to pass.
    flags:
      application_environment: development
      logs_dir: /logs
    args:
      - positional_argument
      - --debug
```
