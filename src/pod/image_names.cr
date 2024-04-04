require "podman"

module Pod::Images
  @@names = Hash(String?, Hash(String, Podman::Image)).new

  def self.[](remote : String?, id : String) : Podman::Image?
    unless images = @@names[remote]?
      images = load_images(remote)
    end
    return images[id]?
  end

  def self.get!(remote, id) : Podman::Image
    self[remote, id] || raise "unknown image: #{id} on #{remote || "localhost"}"
  end

  def self.get_by_name(remote, name) : Array(Podman::Image)
    unless images = @@names[remote]?
      images = load_images(remote)
    end
    images.values.select { |i| i.names.any? { |n| n.ends_with? name } }
  end

  def self.load_images(remote : String?)
    start = Time.utc
    images = Podman.get_images(remote: remote)
    Log.debug { "Loaded #{images.size} podman images in #{Time.utc - start}" }
    @@names[remote] = images.to_h { |i| {i.id, i} }
  end
end
