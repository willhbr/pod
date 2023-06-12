require "./container"

class Pod::ContainerUpdate
  enum Reason
    Start
    Paused
    Exited
    DifferentImage
    NewConfigHash
    NoUpdate
  end

  getter reason : Reason
  getter config : Config::Container
  getter image_id : String
  getter remote : String?
  getter! container : Podman::Container

  def initialize(@reason, @config, @image_id, @remote, @container = nil)
  end

  def actionable?
    !(@reason.no_update? || @reason.paused?)
  end

  def print(io, inspect : Podman::Container::Inspect?)
    case @reason
    when Reason::Start
      io.puts "start: #{@config.name}".colorize(:green)
      print_args_diff(io, [] of String, self.get_args)
    when Reason::Paused
      io.puts "ignoring: #{@config.name} (container paused)".colorize(:yellow)
    when Reason::NoUpdate
      io.puts "no update: #{@config.name}"
    when Reason::Exited
      io.puts "restart: #{@config.name} (currently exited)".colorize(:green)
      print_container_diff(io, inspect.not_nil!)
    when Reason::DifferentImage
      old_image = self.container.id
      new_image = self.image_id
      io.puts "update: #{@config.name} (new image available: #{old_image.truncated}->#{new_image.truncated})".colorize(:blue)
      print_container_diff(io, inspect.not_nil!)
    when Reason::NewConfigHash
      io.puts "update: #{@config.name} (arguments changed)".colorize(:blue)
      print_container_diff(io, inspect.not_nil!)
    end
  end

  private def print_container_diff(io, inspect)
    old_img = container.image_id
    new_img = self.image_id
    unless old_img == new_img
      io.puts "old image: #{self.container.image} (#{self.container.image_id.truncated})"
      io.puts "new image: #{self.config.image} (#{self.image_id.truncated})"
    else
      io.puts "same image: #{self.config.image} (#{self.image_id.truncated})"
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
    when Reason::Start
      io.puts "starting #{name}"
      start_container
      return
    when Reason::Paused
      io.puts "#{name} is paused, not updating.".colorize(:orange)
      return
    when Reason::NoUpdate
      io.puts "#{name} up-to-date. Last updated: #{self.container.uptime} ago."
      return
    when Reason::Exited
      io.puts "#{name} is exited, removing and replacing..."
      remove_container
      start_container
      return
    when Reason::DifferentImage
      io.puts "#{name} is running different image to pulled #{@config.image}"
    when Reason::NewConfigHash
      io.puts "#{name} config has changed, updating..."
    end
    stop_container
    unless self.container.auto_remove
      remove_container
    end
    start_container
  end

  private def to_lines(lines)
    sanitise_command(lines).map_with_index do |line, i|
      if i == 0
        Diff::Line.new(i + 1, Process.quote(line))
      else
        Diff::Line.new(i + 1, "  #{Process.quote(line)}")
      end
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
    @config.to_command(remote: @remote, detached: true,
      cmd_args: nil, override_image: @image_id)
  end

  private def start_container
    Updater.run(self.get_args, remote: nil)
  end

  private def stop_container
    Updater.run({"stop", self.container.id}, remote: @remote)
  end

  private def remove_container
    Updater.run({"rm", self.container.id}, remote: @remote)
  end
end
