require "./config"
require "./container"
require "diff"

class Podman::Manager
  def initialize(@executable : String, @io : IO,
                 &@get_args : Proc(Config::Container, Array(String)))
  end

  def run(args : Enumerable(String)) : String
    process = Process.new(@executable, args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    unless process.wait.success?
      raise "Command `#{@executable} #{Process.quote(args)}` failed: #{error}"
    end
    output
  end

  def get_containers : Array(Podman::Container)
    Array(Podman::Container).from_json(run(%w(container ls -a --format json)))
  end

  def inspect_containers(ids : Enumerable(String)) : Array(Podman::Container::Inspect)
    Array(Podman::Container::Inspect).from_json(run(%w(container inspect) + ids))
  end

  def start_container(config : Config::Container) : String
    args = @get_args.call(config)
    @io.puts "Starting container: #{Process.quote args}"
    output = run(args)
    @io.puts "Run container: #{output}"
    return output
  end

  def stop_container(container : Podman::Container)
    @io.puts "Stopping container: #{container.name}"
    run({"stop", container.id})
  end

  def remove_container(container : Podman::Container)
    run({"rm", container.id})
  end

  def get_update_reason(config : Config::Container, container : Podman::Container) : UpdateReason
    if container.state.paused?
      return UpdateReason::Paused
    end
    if container.state.exited?
      return UpdateReason::Exited
    end

    container_hash = container.pod_hash
    config_hash = config.pod_hash(args: nil)

    # check if image has updated
    if config.image.includes? '/'
      # it's in a registry
      id = run({"pull", config.image, "--quiet"}).strip
    else
      # it's local
      id = run({"image", "ls", config.image, "--quiet"}).strip
    end

    if id != container.image_id
      return UpdateReason::DifferentImage
    elsif config_hash != container_hash
      return UpdateReason::NewConfigHash
    else
      return UpdateReason::NoUpdate
    end
  end

  def update_containers(updates : Array(UpdateInfo))
    updates.each do |info|
      case info.reason
      when UpdateReason::Start
        start_container(info.config)
        next
      when UpdateReason::Paused
        @io.puts "Container is paused, not updating: #{info.config.name}"
        next
      when UpdateReason::NoUpdate
        @io.puts "Container up-to-date. Last updated: #{Time.utc - info.container.not_nil!.created} ago."
        next
      when UpdateReason::Exited
        @io.puts "Container is exited, just starting it again"
        remove_container(info.container.not_nil!)
        start_container(info.config)
        next
      when UpdateReason::DifferentImage
        @io.puts "Container is running different image to pulled #{info.config.image}"
      when UpdateReason::NewConfigHash
        @io.puts "Container config has changed, updating..."
      end
      stop_container(info.container.not_nil!)
      start_container(info.config)
    end
  end

  private def calculate_update(config, container) : UpdateInfo
    if container.nil?
      return UpdateInfo.new(config, nil, UpdateReason::Start)
    end

    reason = self.get_update_reason(config, container)
    return UpdateInfo.new(config, container, reason)
  end

  def print_updates(info, inspections)
    args = [@executable] + @get_args.call(info.config).map { |c| Process.quote(c) }

    if info.reason.start?
      puts "start: #{info.config.name}".colorize(:green)
      print_diff([] of String, args)
      return
    end
    container = info.container.not_nil!
    unless inspect = inspections.delete(container.id)
      raise "did not find inspect result for #{info.config.name}"
    end

    case info.reason
    when UpdateReason::Paused
      @io.puts "ignoring: #{info.config.name} (container paused)".colorize(:yellow)
      return
    when UpdateReason::NoUpdate
      @io.puts "no update: #{info.config.name}"
      return
    when UpdateReason::Exited
      @io.puts "restart: #{info.config.name} (currently exited)".colorize(:green)
    when UpdateReason::DifferentImage
      @io.puts "update: #{info.config.name} (new image available)".colorize(:blue)
    when UpdateReason::NewConfigHash
      @io.puts "update: #{info.config.name} (arguments changed)".colorize(:blue)
    end

    command = inspect.config.create_command.map { |c| Process.quote(c) }
    command.reject! { |a| a.starts_with? "--label=pod_hash=" }
    args.reject! { |a| a.starts_with? "--label=pod_hash=" }
    if command == args
      @io.puts "no change in arguments"
    end
    print_diff(command, args)
    @io.puts "Container started at #{container.started_at} (up #{Time.utc - container.started_at})"
  end

  class UpdateInfo
    getter config : Config::Container
    getter container : Podman::Container?
    getter reason : UpdateReason

    def initialize(@config, @container, @reason)
    end

    def actionable?
      !(@reason.no_update? || @reason.paused?)
    end
  end

  enum UpdateReason
    Start
    Paused
    Exited
    DifferentImage
    NewConfigHash
    NoUpdate
  end

  def calculate_updates(configs : Array(Config::Container)) : Array(UpdateInfo)
    existing_containers = self.get_containers.to_h { |c| {c.name, c} }
    if Set(String).new(configs.map(&.name)).size != configs.size
      raise "container names must be unique for update to work"
    end
    changes = Array(UpdateInfo).new
    configs.each do |config|
      container = existing_containers.delete(config.name)
      changes << calculate_update(config, container)
    end
    changes
  end

  def print_changes(updates : Array(UpdateInfo))
    ids = updates.reject { |u| u.container.nil? }.map { |u| u.container.not_nil!.id }
    inspections = self.inspect_containers(ids).to_h { |i| {i.id, i} }
    updates.each_with_index do |info, idx|
      @io.puts "---" unless idx.zero?

      print_updates(info, inspections)
    end
  end

  private def to_lines(lines)
    lines.map_with_index do |line, i|
      if i == 0
        Diff::Line.new(i + 1, line)
      else
        Diff::Line.new(i + 1, "  #{line}")
      end
    end
  end

  private def print_diff(a, b)
    diff = Diff::MyersLinear.diff(to_lines(a), to_lines(b))
    diff.each do |edit|
      tag = case edit.type
            when Diff::Edit::Type::Delete
              '-'
            when Diff::Edit::Type::Insert
              '+'
            else
              ' '
            end
      color = case edit.type
              when Diff::Edit::Type::Delete
                :red
              when Diff::Edit::Type::Insert
                :green
              else
                :default
              end
      @io.puts "#{tag} #{edit.text.rstrip}".colorize(color)
    end
  end
end
