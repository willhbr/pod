require "inotify"
require "./watcher"

class Actuator
  def initialize(@config : Config::File, @remote : String?, @show : Bool)
  end

  def build(target : String?)
    @config.get_images(target).each do |name, image|
      args = image.to_command(remote: @remote)
      status = run(args)
      unless status.success?
        fail "failed to build #{name}"
      end
    end
  end

  def run(target : String?, detached : Bool?, extra_args : Enumerable(String)?)
    containers = @config.get_containers(target)
    multiple = containers.size > 1
    if multiple
      detached = true
    end
    containers.each do |name, container|
      if container.pull_latest
        run({"pull", container.image})
      end
      args = container.to_command(extra_args, detached: detached, remote: @remote)
      status = run(args, exec: !multiple)
      unless status.success?
        fail "failed to run #{name}"
      end
    end
  end

  def push(target : String?, remote : String?)
    images = @config.get_images(target)
    multiple = images.size > 1
    images.each do |name, image|
      unless tag = image.tag
        raise "can't push image with no tag: #{name}"
      end
      unless push = image.push
        raise "can't push image with no push destination: #{name}"
      end
      if remote
        args = {"--remote=true", "--connection=#{remote}", "push", tag, push}
      else
        args = {"push", tag, push}
      end
      status = run(args: args, exec: !multiple)
      unless status.success?
        fail "failed to run #{name}"
      end
    end
  end

  private def run(args : Enumerable(String), exec : Bool = false) : Process::Status
    if @show
      puts "podman #{Process.quote(args)}"
      return Process::Status.new(0)
    elsif exec
      Process.exec(command: "podman", args: args)
    else
      Process.run(command: "podman", args: args,
        input: Process::Redirect::Close, output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
    end
  end
end
