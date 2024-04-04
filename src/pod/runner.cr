class Pod::Runner
  MAGIC_SHELL = "if which bash > /dev/null 2>&1; then bash; else sh; fi"

  def initialize(@config : Config::File, @remote : String?, @show : Bool, @io : IO)
  end

  def build(target : String?)
    @config.get_images(target).each do |name, image|
      image.apply_overrides! remote: @remote
      args = image.to_command
      t = Time.measure do
        status = run(args)
        unless status.success?
          raise Podman::Exception.new("failed to build #{name}")
        end
      end
      @io.puts "Built #{name} in #{t}".colorize(:blue)
      if image.auto_push
        push_internal(name, image, false)
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
      container.apply_overrides! remote: @remote, detached: detached
      if container.pull_latest
        # TODO this doesn't work with remote
        status = run({"pull", container.image})
        unless status.success?
          raise Podman::Exception.new("failed to pull latest #{container.image}")
        end
      end
      args = container.to_command(extra_args)
      status = run(args, exec: !multiple)
      unless status.success?
        raise Podman::Exception.new("failed to run #{name}")
      end
    end
  end

  def enter(target : String?, extra_args : Enumerable(String)?)
    if target
      unless entrypoint = @config.entrypoints[target]?
        if (image = @config.images[target]?) && (name = image.tag)
          entrypoint = Config::Entrypoint.new(
            image: name
          )
        else
          raise Podman::Exception.new("entrypoint not found: #{target}. Entrypoints are #{@config.entrypoints.keys.join(", ")}.")
        end
      end
    else
      if default = @config.defaults.entrypoint
        entrypoint = @config.entrypoints[default]
      elsif @config.entrypoints.size == 1
        entrypoint = @config.entrypoints.values.first
      elsif @config.images.size == 1
        image = @config.images.values.first
        if name = image.tag
          entrypoint = Config::Entrypoint.new(
            image: name
          )
        else
          raise Podman::Exception.new("no entrypoint specified")
        end
      else
        raise Podman::Exception.new("no entrypoint specified")
      end
    end
    args = entrypoint.to_command(extra_args)
    status = run(args, exec: true)
  end

  def push(target : String?)
    images = @config.get_images(target)
    multiple = images.size > 1
    images.each do |name, image|
      push_internal(name, image, !multiple)
    end
  end

  def update_secrets(target)
    containers = @config.get_containers(target)
    configs = containers.map { |c| c[1] }
    total = 0
    failed = 0
    configs.each do |config|
      config.secrets.each do |name, opts|
        total += 1
        remote = @remote || config.remote
        if local = opts.local
          Log.debug { "Creating secret #{name} from #{local} from local file on #{remote}" }
          contents = File.read(Path[local].expand(home: true))
          status = run(args: {"secret", "create", name, "-"},
            input: IO::Memory.new(contents), remote: remote)
          unless status.success?
            failed += 1
            Log.error { "Failed to create secret: #{name}" }
            next
          end
        elsif remote_path = opts.remote
          Log.debug { "Creating secret #{name} from #{remote_path} from local file on #{remote}" }
          status = run(args: {"secret", "create", name, remote_path}, remote: remote)
          unless status.success?
            failed += 1
            Log.error { "Failed to create secret: #{name}" }
            next
          end
        else
          raise "secrets must set local: or remote: path"
        end
      end
    end

    if failed.zero?
      @io.puts "Updated #{total} secrets".colorize(:green)
    else
      @io.puts "Updated #{total - failed} secrets, #{failed} failed.".colorize(:red)
    end
  end

  private def push_internal(name, image, exec = false)
    unless tag = image.tag
      raise Podman::Exception.new("can't push image with no tag: #{name}")
    end
    unless push = image.push
      raise Podman::Exception.new("can't push image with no push destination: #{name}")
    end
    if remote = @remote || image.remote
      args = {"--remote=true", "--connection=#{remote}", "push", tag, push}
    else
      args = {"push", tag, push}
    end
    start = Time.utc
    status = run(args: args, exec: exec)
    unless status.success?
      raise Podman::Exception.new("failed to push #{name}")
    end
    t = Time.utc - start
    @io.puts "Pushed #{name} in #{t}".colorize(:blue)
  end

  private def run(args : Enumerable(String),
                  exec : Bool = false, input : IO? = nil,
                  remote : String? = nil) : Process::Status
    if @show
      @io.puts "podman #{Process.quote(args)}"
      return Process::Status.new(0)
    elsif exec
      PodmanCLI.exec(args: args, remote: remote)
    else
      PodmanCLI.run_inherit_io(args: args, input: input, remote: remote)
    end
  end
end
