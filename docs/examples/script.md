---
title: "pod script"
layout: page
---

# Pod Script

`pod` can be used to run ad-hoc programs without having to setup a `pods.yaml` config file. This can be useful to run one-off scripts or other tools, although it can be limited with which dependencies are available to the script.

`script` chooses the image based on the file extension and the contents of the script config file. This lives in `~/.config/pod/script.yaml`, and is very similar to the containers section of the `pods.yaml` config:

```yaml
types:
  py:
    name: python
    image: docker.io/library/3.9-alpine
    autoremove: true
    bind_mounts:
      .: /src
    run_flags:
      workdir: /src
      entrypoint: ['python']
  rb:
    name: ruby
    image: docker.io/library/ruby:alpine
    autoremove: true
    bind_mounts:
      .: /src
    run_flags:
      workdir: /src
      entrypoint: ['ruby']
```

It's important that you bind the current working directory to exist in the `--workdir`, as `pod` will pass the file as an argument to the container entrypoint, so the file needs to be accessible within the container. You can pass arguments to the program after a `--` separator, eg:

```shell
$ pod script main.rb -- some other arguments
...
```

The container will be named as the `name` in the config file as well as the input file name.
