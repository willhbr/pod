module Pod::Podman
  PODMAN = "podman"

  private def self.add_remote(args, remote)
    if remote
      a = ["--remote=true", "--connection=#{remote}"]
      a.concat(args)
    else
      args
    end
  end

  def self.exec(args, remote : String? = nil)
    full_args = add_remote(args, remote)
    Log.debug { "exec: #{Process.quote(full_args)}" }
    Process.exec(command: PODMAN, args: full_args)
  end

  def self.run_inherit_io(args, remote : String? = nil,
                          input : Process::Stdio? = nil) : Process::Status
    args = add_remote(args, remote)
    Log.debug { "run: podman #{Process.quote(args)} with input #{input}" }
    Process.run(command: PODMAN, args: args,
      input: input || Process::Redirect::Close, output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit)
  end

  def self.run_inherit_all_io(args, remote : String? = nil) : Process::Status
    args = add_remote(args, remote)
    Log.debug { "run: podman #{Process.quote(args)}" }
    Process.run(command: PODMAN, args: args,
      input: Process::Redirect::Inherit, output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit)
  end

  def self.run_inherit_io!(args, remote : String? = nil)
    status = run_inherit_io(args, remote)
    unless status.success?
      raise Pod::PodmanException.new("podman command failed: #{status.exit_code}", "podman #{Process.quote(args)}")
    end
  end

  def self.run_capture_all(args, remote)
    start = Time.utc
    args = add_remote(args, remote)
    Log.debug { "Running: podman #{Process.quote(args)}" }
    process = Process.new(PODMAN, args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    status = process.wait
    Log.debug { "Run in #{Time.utc - start}" }
    {status, output, error}
  end

  def self.run_capture_stdout(args, remote : String?)
    status, output, error = run_capture_all(args, remote)
    unless status.success?
      raise Pod::PodmanException.new("podman command failed: #{status.exit_code}", "podman #{Process.quote(args)}", error)
    end
    output
  end

  def self.get_containers(names : Array(String), remote : String?) : Array(Podman::Container)
    Array(Podman::Container).from_json(Podman.run_capture_stdout(
      %w(container ls -a --format json) + ["--filter=name=#{names.join('|')}"], remote: remote))
  end

  def self.get_container_by_id(id : String, remote : String?) : Array(Podman::Container)
    Array(Podman::Container).from_json(Podman.run_capture_stdout(
      %w(container ls -a --format json) + ["--filter=id=#{id}"], remote: remote))
  end

  def self.inspect_containers(ids : Enumerable(String), remote : String?) : Array(Podman::Container::Inspect)
    return [] of Podman::Container::Inspect if ids.empty?
    Array(Podman::Container::Inspect).from_json(
      Podman.run_capture_stdout(%w(container inspect) + ids, remote: remote))
  end

  def self.get_container_logs(id, tail, remote)
    args = add_remote ["logs", "--tail", tail.to_s, id], remote

    Log.debug { "Running: podman #{Process.quote(args)}" }
    String.build do |io|
      Process.run("podman", args: args,
        input: Process::Redirect::Close,
        output: io, error: io)
    end
  end

  def self.wait_until_in_state(id : String, remote, states, timeout : Time::Span)
    interrupted = false
    args = add_remote(["wait"] + states.map { |s| "--condition=#{s}" } + [id], remote)
    process = Process.new(PODMAN, args: args,
      input: Process::Redirect::Close,
      output: Process::Redirect::Pipe, error: Process::Redirect::Pipe)
    spawn do
      sleep timeout
      interrupted = true
      process.terminate
    end
    output = process.output.gets_to_end.chomp
    error = process.error.gets_to_end.chomp
    status = process.wait

    return nil if interrupted
    return output.to_i
  end
end
