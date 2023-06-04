require "./config"
require "./container"
require "diff"

module Podman
  class Manager
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

    enum UpdateReason
      Paused
      Exited
      DifferentImage
      NewConfigHash
      NoUpdate
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

    def update_container(config : Config::Container, container : Podman::Container)
      case get_update_reason(config, container)
      when UpdateReason::Paused
        @io.puts "Container is paused, not updating: #{config.name}"
      when UpdateReason::Exited
        @io.puts "Container is exited, just starting it again"
        remove_container(container)
        start_container(config)
      when UpdateReason::DifferentImage
        @io.puts "Container is running different image to pulled #{config.image}"
        stop_container(container)
        start_container(config)
      when UpdateReason::NewConfigHash
        @io.puts "Container config has changed, updating..."
        stop_container(container)
        start_container(config)
      when UpdateReason::NoUpdate
        @io.puts "Container is running latest image and config, no need to update. Last updated: #{Time.utc - container.created} ago."
      end
    end

    def update_containers(configs : Array(Config::Container))
      existing_containers = self.get_containers.to_h { |c| {c.name, c} }
      if Set(String).new(configs.map(&.name)).size != configs.size
        raise "container names must be unique for update to work"
      end
      configs.each do |config|
        begin
          @io.puts "Looking at #{config.name}"
          if container = existing_containers.delete(config.name)
            update_container(config, container)
          else
            start_container(config)
          end
        rescue ex
          Log.error { "Failed to update #{config.name}\n#{ex.message || ex.inspect_with_backtrace}" }
        end
      end
    end

    def inspect_containers(ids : Enumerable(String)) : Array(Podman::Container::Inspect)
      Array(Podman::Container::Inspect).from_json(run(%w(container inspect) + ids))
    end

    private def diff_container(config, container_info)
      args = [@executable] + @get_args.call(config).map { |c| Process.quote(c) }
      if container_info.nil?
        puts "start: #{config.name}".colorize(:green)
        print_args('+', :green, args)
        return
      end
      container = container_info[0]
      inspect = container_info[1]

      case self.get_update_reason(config, container)
      when UpdateReason::Paused
        puts "ignoring: #{config.name} (container paused)".colorize(:yellow)
        return
      when UpdateReason::Exited
        puts "restart: #{config.name} (currently exited)".colorize(:green)
      when UpdateReason::DifferentImage
        puts "update: #{config.name} (new image available)".colorize(:blue)
      when UpdateReason::NewConfigHash
        puts "update: #{config.name} (arguments changed)".colorize(:blue)
      when UpdateReason::NoUpdate
        puts "no update: #{config.name}"
        return
      end

      command = inspect.config.create_command.map { |c| Process.quote(c) }
      if command == args
        puts "no change in arguments"
        print_args('=', :blue, args)
      else
        print_diff(command, args)
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
        print_edit(edit)
      end
    end

    private def print_edit(edit)
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
      puts "#{tag} #{edit.text.rstrip}".colorize(color)
    end

    def diff_containers(configs : Array(Config::Container))
      existing_containers = self.get_containers.to_h { |c| {c.name, c} }
      if Set(String).new(configs.map(&.name)).size != configs.size
        raise "container names must be unique for update to work"
      end
      inspections = self.inspect_containers(existing_containers.values.map &.id).to_h { |i| {i.id, i} }
      configs.each do |config|
        if container = existing_containers.delete(config.name)
          unless insp = inspections.delete(container.id)
            raise "did not find inspect result for #{config.name}"
          end
          diff_container(config, {container, insp})
        else
          diff_container(config, nil)
        end
        puts "---"
      end
    end

    private def print_args(char, color, args)
      args.each_with_index do |arg, idx|
        if idx == 0
          puts "#{char} #{arg}".colorize(color)
        else
          puts "#{char}   #{arg}".colorize(color)
        end
      end
    end
  end
end
