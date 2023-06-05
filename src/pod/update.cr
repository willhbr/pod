require "./config"
require "./container"
require "diff"

class Podman::Manager
  def initialize(@io : IO, @remote : String?)
  end

  def get_args(config)
    config.to_command(remote: @remote, detached: true, cmd_args: nil)
  end

  def self.run(args : Enumerable(String), remote : String?) : String
    if rem = remote
      args = ["--remote=true", "--connection=#{rem}"].concat(args)
    end

    process = Process.new("podman", args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    unless process.wait.success?
      raise "Command `podman #{Process.quote(args)}` failed: #{error}"
    end
    output
  end

  def get_containers(remote : String?) : Array(Podman::Container)
    Array(Podman::Container).from_json(Manager.run(
      %w(container ls -a --format json), remote: remote))
  end

  def inspect_containers(ids : Enumerable(String), remote : String?) : Array(Podman::Container::Inspect)
    return [] of Podman::Container::Inspect if ids.empty?
    Array(Podman::Container::Inspect).from_json(
      Manager.run(%w(container inspect) + ids, remote: remote))
  end

  def start_container(config : Config::Container) : String
    args = get_args(config)
    @io.puts "Starting container:\n  #{Process.quote ["podman"] + args}"
    output = Manager.run(args, remote: nil)
    @io.puts "Run container: #{output}"
    return output
  end

  def stop_container(container : Podman::Container, remote)
    @io.puts "Stopping container: #{container.name}"
    Manager.run({"stop", container.id}, remote: remote)
  end

  def remove_container(container : Podman::Container, remote)
    Manager.run({"rm", container.id}, remote: remote)
  end

  def get_update_reason(config : Config::Container, container : Podman::Container, remote) : UpdateReason
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
      id = Manager.run({"pull", config.image, "--quiet"}, remote: remote).strip
    else
      # it's local
      id = Manager.run({"image", "ls", config.image, "--quiet", "--no-trunc"},
        # I can't see an argument to remove the prefix :(
        remote: remote).strip.lchop("sha256:")
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
      name = info.config.name
      case info.reason
      when UpdateReason::Start
        start_container(info.config)
        next
      when UpdateReason::Paused
        @io.puts "#{name} is paused, not updating.".colorize(:orange)
        next
      when UpdateReason::NoUpdate
        @io.puts "#{name} up-to-date. Last updated: #{Time.utc - info.container.not_nil!.created} ago."
        next
      when UpdateReason::Exited
        @io.puts "#{name} is exited, just starting it again"
        remove_container(info.container.not_nil!, info.remote)
        start_container(info.config)
        next
      when UpdateReason::DifferentImage
        @io.puts "#{name} is running different image to pulled #{info.config.image}"
      when UpdateReason::NewConfigHash
        @io.puts "#{name} config has changed, updating..."
      end
      stop_container(info.container.not_nil!, info.remote)
      start_container(info.config)
    end
  end

  private def calculate_update(config, container, remote) : UpdateInfo
    if container.nil?
      return UpdateInfo.new(config, nil, UpdateReason::Start, remote)
    end

    reason = self.get_update_reason(config, container, remote)
    return UpdateInfo.new(config, container, reason, remote)
  end

  def print_updates(info, inspections)
    args = ["podman"] + self.get_args(info.config).map { |c| Process.quote(c) }

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
    getter remote : String?

    def initialize(@config, @container, @reason, @remote)
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

  def calculate_updates(input_configs : Array(Config::Container)) : Array(UpdateInfo)
    if Set(String).new(input_configs.map(&.name)).size != input_configs.size
      raise "container names must be unique for update to work"
    end
    configs_per_host = Hash(String?, Array(Config::Container)).new do |hash, key|
      hash[key] = Array(Config::Container).new
    end
    input_configs.each do |config|
      configs_per_host[@remote || config.remote] << config
    end
    changes = Array(UpdateInfo).new
    configs_per_host.each do |host, configs|
      existing_containers = self.get_containers(host).to_h { |c| {c.name, c} }
      configs.each do |config|
        container = existing_containers.delete(config.name)
        changes << calculate_update(config, container, host)
      end
    end
    changes
  end

  def print_changes(all_updates : Array(UpdateInfo))
    updates_per_host = Hash(String?, Array(UpdateInfo)).new do |hash, key|
      hash[key] = Array(UpdateInfo).new
    end
    all_updates.each do |update|
      updates_per_host[update.remote] << update
    end
    updates_per_host.each do |host, updates|
      ids = updates.reject { |u| u.container.nil? }.map { |u| u.container.not_nil!.id }
      inspections = self.inspect_containers(ids, host).to_h { |i| {i.id, i} }
      updates.each_with_index do |info, idx|
        print_updates(info, inspections)
      end
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
