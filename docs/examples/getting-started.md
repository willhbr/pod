---
title: "Getting Started"
layout: page
---

This page shows you how to setup a project using pod. It assumes a reasonable understanding of Podman and how to write containerfiles.

Start by running `pod init`—this will create a directory for your project, and let you run any language-specific initialisers to scaffold your project.

```shell
$ pod init
Project name [Projects] my-cool-project
Base image for development: docker.io/crystallang/crystal:latest
Trying to pull docker.io/crystallang/crystal:latest...
Getting image source signatures
Copying blob 96ac260f719c skipped: already exists
Copying blob 9d19ee268e0d skipped: already exists
Copying blob e798b0d318d7 skipped: already exists
Copying blob 76639df9a8a9 skipped: already exists
Copying config 3cd9bc411b done
Writing manifest to image destination
Storing signatures
3cd9bc411bf1062d92831ab85c70f81bd1ee7993d21a5ffd53d674b52da1868d
Enter container to setup project now? [Y/n]
root@aec5d6273248:/my-cool-project# ls
root@aec5d6273248:/my-cool-project# crystal init app .
    create  /my-cool-project/.gitignore
    create  /my-cool-project/.editorconfig
    create  /my-cool-project/LICENSE
    create  /my-cool-project/README.md
    create  /my-cool-project/shard.yml
    create  /my-cool-project/src/my-cool-project.cr
    create  /my-cool-project/spec/spec_helper.cr
    create  /my-cool-project/spec/my-cool-project_spec.cr
Initialized empty Git repository in /my-cool-project/.git/
root@aec5d6273248:/my-cool-project# exit
exit
Setup complete? [Y/n]
Removing container used for setup: my-cool-project-setup

 [1] .git
 [2] spec
 [3] src
 [4] None of these

Which directory has the source files? [3] 3
Initialised project in /home/will/Projects/my-cool-project
```

`pod init` will ask for:

- Project name
- Base image (you can change this later)
- Directory containing source files

During setup pod will run a shell using image you specified. Use this to use the build tool of your language to create a project—like `cargo init` or `npm init`. In the example above I use `crystal init app .`.

> If you later want to run a shell to get access to the inner build tools (to do something like run a code generator) you can run `pod enter shell`. This is configured in the `entrypoints` section of the `pods.yaml` file.

We've now got two containerfiles, and a `pods.yaml` file that tells pod what to do. Pod makes some guesses about your project to setup the containerfiles, but you should check that they make sense before building an image.

`Containerfile.dev` will be used to create a development image, where we can bind-mount our source code in. This gives us a containerised environment without paying a large overhead of rebuilding an image every time we change our code (or even allowing live reloading, depending on the language we're using). This is the default file for a Crystal project:

```
FROM docker.io/crystallang/crystal:latest-alpine
WORKDIR /src
COPY shard.yml .
RUN shards install
ENTRYPOINT ["shards", "run", "--error-trace", "--"]
```

This installs any dependencies and uses `shards run` to run the default target of our project. We will need to rebuild the image if our dependencies change, but that shouldn't happen too often. Once you're happy with the contents of `Containerfile.dev`, you can build a dev image:

```shell
$ pod build dev
STEP 1/5: FROM docker.io/crystallang/crystal:latest-alpine AS builder
STEP 2/5: WORKDIR /src
--> Using cache a61f4f23a678caed77fd07ad3f619e807153d4e77b5776caa5bb89261528b286
--> a61f4f23a67
STEP 3/5: COPY shard.yml .
--> 7f568ea75c3
STEP 4/5: RUN shards install
Resolving dependencies
Writing shard.lock
--> 911e98c4dee
STEP 5/5: ENTRYPOINT ["shards", "run", "--error-trace", "--"]
COMMIT my-project:dev-latest
--> 6d89adbf519
Successfully tagged localhost/test-project:dev-latest
6d89adbf5190f94c4950ff2476e66cc2ea4f3c1982b3a40aab1e4c60c4b44b4b
Built dev in 4.0s
```

Before we run it, open `pods.yaml` and find the `containers.dev` section. It has a bunch of default values to illustrate the options you might need—like passing some arguments through to your program, or exposing ports. For our dev image, critical thing is:

```yaml
bind_mounts:
  # binding the source directory lets us re-run changes without rebuilding
  src: /src/src
```

Without this, our container wouldn't have any code to run! You might need to change this for other languages that put their code in a different directory. For example if you're using Swift you might do `Sources: /src/Sources` (`/src` is the default working directory, which is set with `WORKDIR` in our containerfile).

We're almost ready to run our image. I edited the main file of my Crystal project to print "Hello pods!" so I know it's actually done the right thing. We can run it with:

```shell
$ pod run dev
Dependencies are satisfied
Building: test-project
Executing: test-project
Hello pods!
```

Perfect!

> you can set `defaults.build` and `defaults.run` in `pods.yaml` to specify the default target to build and run, which saves you from specifying it every time. This shortens the above command to just `pod r`.

Now we can do the easy part—write a useful application. You go off and do that, then we can continue and make a production image.

`Containerfile.prod` can be very similar to our dev version, but for compiled languages we can use a two-stage containerfile to make our final image smaller. For Crystal projects I use a containerfile that looks something like:

```
FROM docker.io/crystallang/crystal:latest-alpine AS builder
WORKDIR /src
COPY . .
RUN shards install
RUN shards build --error-trace --release --progress --static

FROM docker.io/alpine:latest
COPY --from=builder /src/bin/my-project /bin/my-project
ENTRYPOINT ["/bin/my-project"]
```

The first image (named `builder`) uses the `crystal:latest-alpine` image to produce a statically linked release binary. For Rust we might do something like `cargo build --release` here. The second image just uses an unadorned `alpine` image to run the program, copying just the executable from the previous image. If your program relies on some static assets, you'll need to copy them into this image.

We build our production image just like the dev one:

```shell
$ pod build prod
...
[2/2] COMMIT my-project:prod-latest
--> 98cca2532dd
Successfully tagged localhost/my-project:prod-latest
98cca2532dd23a7388ed02e396b9120795eaac96a599f9a8515cc6c36af438ee
Built prod in 14s
```

> You can define a repository and tag that the image should get pushed to using the `push` attribute on the image definition. `auto_push: true` means this will be done after every successful build.

We could just use `pod run prod` to run a container from our image, but that's boring. Instead we'll use `pod update prod` to compare with currently running images and apply changes.

Run `pod update prod` and you should see that pod will start a new container since there isn't one running yet. (I've removed some of the default options from `containers` in `pods.yaml`, I'm assuming that you've altered the config for your job).

```shell
$ pod update prod
Starting my-project-prod
```

Now let's make a change to the `pods.yaml` config file, I'm going to pass a flag into my program by adding to `flags` in the `container` definition. I can update my container:

```shell
$ pod update -d prod
update: my-project-prod (arguments changed)
same image: localhost/my-project:prod-latest (ce7aa8f92c2d) 2023-10-05 12:40:49 UTC
  podman
    run
    --detach=true
    --rm=true
    --name=my-project-prod
    --hostname=my-project-prod
    ce7aa8f92c2d289f5267260c3e643791bf0196b46971771e9619aad47129c2a3
+   --enable_feature=true
Container started at 2023-10-05 12:41:58 UTC (up 2m56s)
update? [y/N]
```

This will tell me some useful information; I'm going to be running the same image (I haven't changed any code or built a new one), I'm not changing any of the flags to podman, just adding a new flag to my program, and finally the existing container has been running for just under three minutes. If I type `y` and press enter, pod will stop the existing container, and start a new one in its place.

`pod update` can update multiple containers, even across multiple machines by specifying `remote` on the container configuration.

---

You should now be able to setup a project using pod, build an image for development, iterate quickly without having to wait for image rebuilds, and create a production image that can be quickly pushed using `pod update`.
