require "./config"
require "./container"
require "diff"

class String
  def truncated
    self[...12]
  end
end

class Pod::Updater
  include ContainerInspectionUtils

  def initialize(@io : IO, @remote : String?)
  end

  private def resolve_new_image(image, remote) : Podman::Image
    # check if image has updated
    if image.includes?('/') && !image.starts_with?("localhost/")
      # it's in a registry
      Log.info { "Trying to pull new version of #{image}" }
      @io.puts "Pulling new version of #{image}"
      id = ContainerInspectionUtils.run({"pull", image, "--quiet"}, remote: remote).strip
      @io.puts "Pulled #{image}@#{id.truncated}"
    end

    # it's now local
    Log.info { "Getting ID of image #{image}" }
    images = Pod::Images.get_by_name(remote, image)

    if images.empty?
      raise Pod::Exception.new "image not found: #{image}"
    end
    if images.size != 1
      raise Pod::Exception.new "multiple images match: #{image} (#{images.join(", ")})"
    end
    Log.info { "Image #{image} id: #{images[0].id}" }
    return images[0]
  end

  private def calculate_update(config, container, remote) : ContainerUpdate
    if container && container.state.paused?
      return ContainerUpdate.new(:paused, config, remote, container)
    end

    image = self.resolve_new_image(config.image, remote)
    config.apply_overrides! image: image.id

    if container.nil?
      return ContainerUpdate.new(:start, config,
        remote)
    end

    container_hash = container.pod_hash
    config_hash = config.pod_hash(args: nil)

    if image.id != container.image_id
      return ContainerUpdate.new(:different_image, config,
        remote, container)
    elsif config_hash != container_hash
      return ContainerUpdate.new(:new_config_hash, config,
        remote, container)
    else
      unless container.state.running?
        return ContainerUpdate.new(:exited, config,
          remote, container)
      end

      return ContainerUpdate.new(:no_update, config,
        remote, container)
    end
  end

  def update_containers(updates : Array(ContainerUpdate))
    updates.each do |info|
      info.update(@io)
    end
  end

  def calculate_updates(input_configs : Array(Config::Container)) : Array(ContainerUpdate)
    configs_per_host = Hash(String?, Array(Config::Container)).new do |hash, key|
      hash[key] = Array(Config::Container).new
    end
    input_configs.each do |config|
      configs_per_host[@remote || config.remote] << config
    end
    changes = Array(ContainerUpdate).new
    configs_per_host.each do |host, configs|
      if Set(String).new(configs.map(&.name)).size != configs.size
        raise Pod::Exception.new("container names must be unique for update to work")
      end
      existing_containers = self.get_containers(configs.map(&.name), host).to_h { |c| {c.name, c} }
      Geode::Spindle.run do |spindle|
        configs.each do |config|
          # Not threadsafe at all but whatever
          container = existing_containers.delete(config.name)
          spindle.spawn do
            changes << calculate_update(config, container, host)
          end
        end
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
      ids = updates.reject { |u| u.container?.nil? }.map { |u| u.container.id }
      inspections = self.inspect_containers(ids, host).to_h { |i| {i.id, i} }
      updates.each do |info|
        if id = info.container?.try &.id
          inspection = inspections.delete(id)
        end
        info.print(@io, inspection)
      end
    end
  end
end
