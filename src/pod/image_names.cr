require "json"
require "./container_inspection_utils"

class Pod::Podman::Image
  include JSON::Serializable
  @[JSON::Field(key: "Id")]
  getter id : String
  @[JSON::Field(key: "Names")]
  getter names = Array(String).new
  @[JSON::Field(key: "Created", converter: Time::EpochConverter)]
  getter created : Time

  def name
    @names.first || id.truncated
  end

  def to_s(io)
    if name = @names.first?
      io << name << " (" << @id.truncated << ')'
    else
      io << @id.truncated
    end
    io << ' '
    @created.to_s(io)
  end

  def_equals @id
end

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
    images = Array(Podman::Image).from_json(
      Podman.run_capture_stdout(%w(image ls --format json), remote: remote))
    Log.debug { "Loaded #{images.size} podman images in #{Time.utc - start}" }
    @@names[remote] = images.to_h { |i| {i.id, i} }
  end
end
