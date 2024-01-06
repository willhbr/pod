module Pod::ContainerInspectionUtils
  def self.run(args, remote)
    return run_yield(args, remote) do
    end
  end

  private def self.run_internal(args, remote)
    if rem = remote
      args = ["--remote=true", "--connection=#{rem}"].concat(args)
    end

    Log.debug { "Running: podman #{Process.quote(args)}" }
    Process.new("podman", args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
  end

  def self.run_yield(args : Enumerable(String), remote : String?) : String
    start = Time.utc
    process = run_internal(args, remote)
    yield process
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    status = process.wait
    Log.debug { "Run in #{Time.utc - start}" }
    unless status.success?
      raise Pod::PodmanException.new("podman command failed: #{status.exit_code}", "podman #{Process.quote(args)}", error)
    end
    output
  end

  def self.run_yield_nofail(args : Enumerable(String), remote : String?) : String
    start = Time.utc
    process = run_internal(args, remote)
    yield process
    output = process.output.gets_to_end.chomp
    process.wait
    Log.debug { "Run in #{Time.utc - start}" }
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
