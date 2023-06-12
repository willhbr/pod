require "./config"
require "./container"
require "diff"

class String
  def truncated
    self[...12]
  end
end

class Pod::Updater
  def initialize(@io : IO, @remote : String?, @state_store : Pod::StateStore)
  end

  def self.run(args : Enumerable(String), remote : String?) : String
    if rem = remote
      args = ["--remote=true", "--connection=#{rem}"].concat(args)
    end

    Log.debug { "Running: podman #{Process.quote(args)}" }
    process = Process.new("podman", args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    unless process.wait.success?
      raise Pod::Exception.new("Command `podman #{Process.quote(args)}` failed: #{error}")
    end
    output
  end

  def get_containers(names : Array(String), remote : String?) : Array(Podman::Container)
    Array(Podman::Container).from_json(Updater.run(
      %w(container ls -a --format json) + ["--filter=name=#{names.join('|')}"], remote: remote))
  end

  def inspect_containers(ids : Enumerable(String), remote : String?) : Array(Podman::Container::Inspect)
    return [] of Podman::Container::Inspect if ids.empty?
    Array(Podman::Container::Inspect).from_json(
      Updater.run(%w(container inspect) + ids, remote: remote))
  end

  struct ImageId
    include JSON::Serializable
    @[JSON::Field(key: "Id")]
    getter id : String
    @[JSON::Field(key: "CreatedAt")]
    getter created_at : Time
  end

  private def resolve_new_image(image, remote) : ImageId
    # check if image has updated
    if image.includes?('/') && !image.starts_with?("localhost/")
      # it's in a registry
      Log.info { "Trying to pull new version of #{image}" }
      id = Updater.run({"pull", image, "--quiet"}, remote: remote).strip
    end
    # it's now local
    Log.info { "Getting ID of image #{image}" }
    images = Array(ImageId).from_json(Updater.run(
      {"image", "ls", image, "--format=json"}, remote: remote))
    if images.empty?
      raise Pod::Exception.new "image not found: #{image}"
    end
    ids = Set(String).new(images.map(&.id))
    if ids.size != 1
      raise Pod::Exception.new "multiple images match: #{image} (#{ids.join(", ")})"
    end
    return images[0]
  end

  private def calculate_update(config, container, remote, override_image : String? = nil) : ContainerUpdate
    if container && container.state.paused?
      return ContainerUpdate.new(:paused, config,
        container.image_id, remote, Time.utc, container)
    end

    image = self.resolve_new_image(override_image || config.image, remote)
    if container.nil?
      return ContainerUpdate.new(:start, config,
        image.id, remote, image.created_at)
    end

    if container.state.exited?
      return ContainerUpdate.new(:exited, config,
        image.id, remote, image.created_at, container)
    end

    container_hash = container.pod_hash
    config_hash = config.pod_hash(args: nil)

    if image.id != container.image_id
      return ContainerUpdate.new(:different_image, config,
        image.id, remote, image.created_at, container)
    elsif config_hash != container_hash
      return ContainerUpdate.new(:new_config_hash, config,
        image.id, remote, image.created_at, container)
    else
      return ContainerUpdate.new(:no_update, config,
        image.id, remote, image.created_at, container)
    end
  end

  def update_containers(updates : Array(ContainerUpdate))
    updates.each do |info|
      info.update(@io)
      if info.actionable?
        @state_store.record(info.remote, info.config, info.image_id)
      end
    end
  end

  def calculate_updates(input_configs : Array(Config::Container)) : Array(ContainerUpdate)
    if Set(String).new(input_configs.map(&.name)).size != input_configs.size
      raise Pod::Exception.new("container names must be unique for update to work")
    end
    configs_per_host = Hash(String?, Array(Config::Container)).new do |hash, key|
      hash[key] = Array(Config::Container).new
    end
    input_configs.each do |config|
      configs_per_host[@remote || config.remote] << config
    end
    changes = Array(ContainerUpdate).new
    configs_per_host.each do |host, configs|
      existing_containers = self.get_containers(configs.map(&.name), host).to_h { |c| {c.name, c} }
      configs.each do |config|
        container = existing_containers.delete(config.name)
        changes << calculate_update(config, container, host)
      end
    end
    changes
  end

  def print_changes(all_updates : Array(ContainerUpdate))
    updates_per_host = Hash(String?, Array(ContainerUpdate)).new do |hash, key|
      hash[key] = Array(ContainerUpdate).new
    end
    all_updates.each do |update|
      updates_per_host[update.remote] << update
    end
    updates_per_host.each do |host, updates|
      ids = updates.reject { |u| u.container.nil? }.map { |u| u.container.not_nil!.id }
      inspections = self.inspect_containers(ids, host).to_h { |i| {i.id, i} }
      updates.each do |info|
        if id = info.container?.try &.id
          inspection = inspections.delete(id)
        end
        info.print(@io, inspection)
      end
    end
  end

  def calculate_reversions(states : Array(StateStore::ContainerState))
    configs_per_host = Hash(String?, Array(StateStore::ContainerState)).new do |hash, key|
      hash[key] = Array(StateStore::ContainerState).new
    end
    states.each do |state|
      configs_per_host[@remote || state.config.remote] << state
    end
    changes = Array(ContainerUpdate).new
    configs_per_host.each do |host, states|
      existing_containers = self.get_containers(states.map { |s| s.config.name }, host).to_h { |c| {c.name, c} }
      states.each do |state|
        container = existing_containers.delete(state.config.name)
        changes << calculate_update(state.config, container, host,
          override_image: state.image_id)
      end
    end
    changes
  end
end
