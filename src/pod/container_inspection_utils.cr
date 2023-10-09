module Pod::ContainerInspectionUtils
  def self.run(args : Enumerable(String), remote : String?) : String
    if rem = remote
      args = ["--remote=true", "--connection=#{rem}"].concat(args)
    end

    Log.debug { "Running: podman #{Process.quote(args)}" }
    start = Time.utc
    process = Process.new("podman", args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    status = process.wait
    Log.debug { "Run in #{Time.utc - start}" }
    unless status.success?
      raise Pod::Exception.new("Command `podman #{Process.quote(args)}` failed: #{error}")
    end
    output
  end

  def get_containers(names : Array(String), remote : String?) : Array(Podman::Container)
    Array(Podman::Container).from_json(ContainerInspectionUtils.run(
      %w(container ls -a --format json) + ["--filter=name=#{names.join('|')}"], remote: remote))
  end

  def get_container_by_id(id : String, remote : String?) : Array(Podman::Container)
    Array(Podman::Container).from_json(ContainerInspectionUtils.run(
      %w(container ls -a --format json) + ["--filter=id=#{id}"], remote: remote))
  end

  def inspect_containers(ids : Enumerable(String), remote : String?) : Array(Podman::Container::Inspect)
    return [] of Podman::Container::Inspect if ids.empty?
    Array(Podman::Container::Inspect).from_json(
      ContainerInspectionUtils.run(%w(container inspect) + ids, remote: remote))
  end
end
