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

  class IBuilder < Watcher
    @process : Process? = nil

    def initialize(@actuator : Actuator, @images : Array({String, Config::Image}))
      @gitignore = Gitignore.new
      @images.each do |_, img|
        p = Path[img.context] / ".gitignore"
        if File.exists? p
          @gitignore.add p
        end
      end
    end

    def run
      @images.each do |name, image|
        args = image.to_command(remote: @actuator.@remote)
        @process = process = run(args)
        status = process.wait
        @process = nil
        if status.success?
          puts "built #{name} successfully"
        else
          puts "failed to build #{name}"
          break
        end
        return unless self.running?
      end
    end

    def good_change?(path : Path) : Bool
      !@gitignore.includes? path
    end

    private def run(args : Enumerable(String)) : Process
      Process.new(command: "podman", args: args,
        input: Process::Redirect::Close, output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)
    end

    def handle_interrupt
      @process.try &.signal Signal::INT
    end
  end

  def ibuild(target : String?)
    images = @config.get_images(target)
    ib = IBuilder.new(self, images)
    Signal::INT.trap do
      ib.interrupt
    rescue ex
      Log.error(exception: ex) { "Interrupt failed" }
    end
    ib.watch(images.map { |_, i| i.context })
    Signal::INT.reset
  end

  def run(target : String?, detached : Bool?, extra_args : Enumerable(String)?)
    containers = @config.get_containers(target)
    multiple = containers.size > 1
    if multiple
      detached = true
    end
    containers.each do |name, container|
      args = container.to_command(extra_args, detached: detached, remote: @remote)
      status = run(args)
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
