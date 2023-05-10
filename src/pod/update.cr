module Podman
  class Manager
    def initialize(@executable : String, &@get_args : Proc(Config::Container, Array(String)))
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
      Log.info { "Listing containers" }
      Array(Podman::Container).from_json(run(%w(container ls -a --format json)))
    end

    def start_container(config : Config::Container) : String
      args = @get_args.call(config)
      Log.info { "Starting container: #{Process.quote args}" }
      output = run(args)
      Log.info { "Run container: #{output}" }
      return output
    end

    def stop_container(container : Podman::Container)
      Log.info { "Stopping container: #{container.name}" }
      run({"stop", container.id})
    end

    def remove_container(container : Podman::Container)
      Log.info { "Removing container: #{container.name}" }
      run({"rm", container.id})
    end

    def update_container(config : Config::Container, container : Podman::Container)
      Log.info { "Updating container #{config.name}" }
      #      policy = config.update
      if container.state.paused?
        Log.info { "Container is paused, not updating: #{config.name}" }
        return
      end
      if container.state.exited?
        Log.info { "Container is exited, just starting it again" }
        remove_container(container)
        start_container(config)
        return
      end

      container_hash = container.pod_hash
      config_hash = config.pod_hash(args: nil)

      # check if image has updated
      id = run({"pull", config.image, "--quiet"}).strip

      if id != container.image_id
        Log.info { "Container is running different image to pulled #{config.image}" }
        stop_container(container)
        # All images have --rm so no need to delete
        start_container(config)
      elsif config_hash != container_hash
        Log.info { "Container config has changed, updating..." }
        stop_container(container)
        # All images have --rm so no need to delete
        start_container(config)
      else
        Log.info { "Container is running latest image and config, no need to update" }
      end
    end

    def update_containers(configs : Array(Config::Container))
      Log.info { "Updating containers" }
      existing_containers = self.get_containers.to_h { |c| {c.name, c} }
      if Set(String).new(configs.map(&.name)).size != configs.size
        raise "container names must be unique for update to work"
      end
      configs.each do |config|
        begin
          Log.info { "Looking at #{config.name}" }
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
  end
end
