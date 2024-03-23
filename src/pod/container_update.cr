require "./container"

class Pod::ContainerUpdate
  enum Reason
    Bounce
    Start
    Paused
    Exited
    DifferentImage
    NewConfigHash
    NoUpdate
  end

  getter reason : Reason
  getter config : Config::Container
  getter remote : String?
  getter! container : Podman::Container

  def initialize(@reason, @config, @remote, @container = nil)
  end

  def actionable?
    !(@reason.no_update? || @reason.paused?)
  end

  def print(io, inspect : Podman::Container::Inspect?)
    name = @config.name
    case @reason
    when Reason::Bounce
      io.puts "bounce: #{name}".colorize(:green)
    when Reason::Start
      io.puts "start: #{name}".colorize(:green)
      print_args_diff(io, [] of String, self.get_args)
    when Reason::Paused
      io.puts "ignoring: #{name} (container paused)".colorize(:yellow)
    when Reason::NoUpdate
      io.puts "no update: #{name}. Last updated: #{self.container.uptime} ago.".colorize(:magenta)
    when Reason::Exited
      io.puts "restart: #{name} (currently exited)".colorize(:green)
      print_container_diff(io, inspect.not_nil!)
    when Reason::DifferentImage
      io.puts "update: #{name} (new image available)".colorize(:blue)
      print_container_diff(io, inspect.not_nil!)
    when Reason::NewConfigHash
      io.puts "update: #{name} (arguments changed)".colorize(:blue)
      print_container_diff(io, inspect.not_nil!)
    end
  end

  private def print_container_diff(io, inspect)
    old_image = Pod::Images.get! config.remote, container.image_id
    # If it doesn't have the tag, add the tag to
    old_image.names << "<#{container.image}>"
    new_image = Pod::Images.get! config.remote, self.config.image
    unless old_image == new_image
      io.puts "old image: #{old_image}".colorize(:red)
      io.puts "new image: #{new_image}".colorize(:green)
    else
      io.puts "same image: #{new_image}".colorize(:blue)
    end

    old_args = inspect.config.create_command
    new_args = ["podman"] + self.get_args
    if old_args == new_args
      io.puts "no change in arguments"
    end
    print_args_diff(io, old_args, new_args)
    io.puts "Container started at #{container.started_at} (up #{container.uptime})"
  end

  def update(io)
    name = @config.name
    case @reason
    when Reason::Bounce
      io.puts "bouncing #{name}..."
    when Reason::Start
      io.puts "starting #{name}"
      id = start_container
      check_container_ok(id)
      return
    when Reason::Paused
      io.puts "#{name} is paused, not updating.".colorize(:yellow)
      return
    when Reason::NoUpdate
      io.puts "#{name} up-to-date. Last updated: #{self.container.uptime} ago.".colorize(:magenta)
      return
    when Reason::Exited
      io.puts "#{name} is exited, restarting...".colorize(:green)
      Podman.run_capture_stdout({"start", self.container.id}, remote: @remote)
      check_container_ok(self.container.id)
      return
    when Reason::DifferentImage
      io.puts "#{name} is running different image to pulled #{@config.image.truncated}"
    when Reason::NewConfigHash
      io.puts "#{name} config has changed, updating...".colorize(:blue)
    end
    stop_container
    io.puts "stopped old container".colorize(:blue)
    old_name = nil
    unless self.container.auto_remove
      old_name = rename_container
      io.puts "renamed old container to #{old_name}"
    else
      Log.info { "Not doing healthcheck on container since old version was autoremoved" }
    end
    new_id : String? = nil
    begin
      new_id = start_container
      io.puts "started new container: #{new_id.truncated}".colorize(:green)
      check_container_ok(new_id)
      remove_container
    rescue ex : Pod::Exception
      unless old_name.nil?
        io.puts "failed to update #{@config.name}".colorize(:red)
        io.puts "restarting old container #{self.container.id.truncated}"
        if id = new_id
          io.puts "removing failed container #{id.truncated}".colorize(:blue)
          Podman.run_capture_stdout({"stop", id}, remote: @remote)
          Podman.run_capture_stdout({"rm", id}, remote: @remote)
        end
        restart_old_container
        io.puts "restarted old #{@config.name}: #{self.container.id}".colorize(:green)
      end
      raise ex
    end
  end

  private def check_container_ok(id : String)
    timeout = 5.seconds
    if health = @config.health
      Log.warn { "health checking not yet supported on Will's podman version" }
      # check_reached_state(id, %w(healthy))
      if t = health.start_period
        timeout = Time::Span.from_string(t) rescue 5.seconds
      end
    end
    if exit_code = Podman.wait_until_in_state(id, @remote, %w(stopped exited), timeout)
      logs = Podman.get_container_logs(id, tail: 15, remote: @remote)
      raise Pod::Exception.new(
        "#{@config.name} exited fast with status #{exit_code}",
        container_logs: logs)
    end
  end

  private def to_lines(lines)
    sanitise_command(lines).map_with_index do |line, i|
      Diff::Line.new(i + 1, "  #{Process.quote(line)}")
    end
  end

  def sanitise_command(args : Enumerable(String))
    args.reject do |arg|
      arg.starts_with? "--label=pod_hash="
    end
  end

  private def print_args_diff(io, a, b)
    Diff::MyersLinear.diff(to_lines(a), to_lines(b)).each do |edit|
      case edit.type
      when Diff::Edit::Type::Delete
        tag = '-'
        color = :red
      when Diff::Edit::Type::Insert
        tag = '+'
        color = :green
      else
        tag = ' '
        color = :default
      end
      io.puts "#{tag} #{edit.text.rstrip}".colorize(color)
    end
  end

  private def get_args
    @config.to_command(cmd_args: nil)
  end

  private def start_container : String
    Podman.run_capture_stdout(self.get_args, remote: nil)
  end

  private def stop_container
    Podman.run_capture_stdout({"stop", self.container.id}, remote: @remote)
  end

  private def rename_container
    name = "#{@config.name}_old_#{self.container.id.truncated}"
    Podman.run_inherit_io!({"rename", self.container.id, name}, remote: @remote)
    name
  end

  private def remove_container
    Podman.run_capture_stdout({"rm", self.container.id}, remote: @remote)
  end

  private def restart_old_container
    Podman.run_inherit_io!({"rename", self.container.id, self.container.name}, remote: @remote)
    Podman.run_inherit_io!({"start", self.container.id}, remote: @remote)
  end
end
