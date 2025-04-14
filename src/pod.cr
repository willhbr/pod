require "yaml"
require "./pod/*"
require "option_parser"
require "geode"
require "ecr"

module Pod
  VERSION = "0.1.0"

  def self.build_info
    "#{Geode::ProgramInfo::BUILT_AT}, #{Crystal::VERSION}"
  end
end

module Pod::CLI::Subcommand
  getter! globals : PodOptions
  getter target : String? = nil

  abstract def use_parser(p : OptionParser)
  abstract def run(args : Array(String))

  def docs : String
    {% begin %}
    {{ @type }}::DOCS
    {% end %}
  end

  def set_global_opts(@globals : PodOptions)
  end

  def usage(str)
    "Usage: pod #{{% begin %}{{ @type }}::CMD{% end %}} #{str}"
  end

  def with_target(p)
    p.before_each do |flag|
      unless flag.starts_with? '-'
        @target = flag
        p.stop
      end
    end
  end
end

class RunOptions
  include Pod::CLI::Subcommand
  CMD  = "run"
  DESC = "run a container"
  DOCS = <<-DOC
  Run a container.

  Runs a container as configured in the config file. If no target name is given,
  runs the container specified by defaults.run or if there is only one container
  configured, runs that.
  DOC

  @show_only = false
  @detached : Bool? = nil

  def use_parser(p)
    p.banner = usage("[options] <target>")
    with_target(p)
    p.on("-s", "--show", "show the command, don't run it") { @show_only = true }
    p.on("-d", "--detach", "run container detached") { @detached = true }
    p.on("-i", "--interactive", "run container interactively") { @detached = false }
  end

  def run(args)
    target = @target
    config = globals.config
    Pod::Runner.new(config, globals.@remote_host, @show_only, STDOUT).run(
      target, @detached, args.empty? ? nil : args)
  end
end

class BuildOptions
  include Pod::CLI::Subcommand
  CMD  = "build"
  DESC = "build image(s)"
  DOCS = <<-DOC
  Build one or more images.
  DOC
  @show_only = false

  def use_parser(p)
    p.banner = usage("[options] <target>")
    with_target(p)
    p.on("-s", "--show", "show the command, don't run it") { @show_only = true }
  end

  def run(args)
    target = @target
    actuator = Pod::Runner.new(globals.config,
      globals.@remote_host, @show_only, STDOUT)
    actuator.build(target)
  end
end

class PushOptions
  include Pod::CLI::Subcommand
  CMD  = "push"
  DESC = "push image(s) to remote or registry"
  DOCS = <<-DOC
  Push images to specified remote host or registry
  DOC
  @show_only = false

  def use_parser(p)
    p.banner = usage("[options] <target>")
    with_target(p)
    p.on("-s", "--show", "show the command, don't run it") { @show_only = true }
  end

  def run(args)
    target = @target
    actuator = Pod::Runner.new(globals.config,
      globals.@remote_host, @show_only, STDOUT)
    actuator.push(target)
  end
end

class DiffOptions
  include Pod::CLI::Subcommand
  CMD  = "diff"
  DESC = "show diff of updating containers"
  DOCS = <<-DOC
  Show the diff that would be applied by `update`.
  DOC

  def use_parser(p)
    p.banner = usage("[options] <target>")
    with_target(p)
  end

  def run(args)
    config = globals.config
    manager = Pod::Updater.new(STDOUT, globals.@remote_host, false)
    target = @target || config.defaults.update
    configs = config.get_containers(target).map { |c| c[1] }
    configs.each { |c| c.resolve_refs(config) }
    updates = manager.calculate_updates(configs)
    manager.print_changes(updates)
  end
end

class UpdateOptions
  include Pod::CLI::Subcommand
  CMD  = "update"
  DESC = "update containers to match config"
  DOCS = <<-DOC
  Update containers to match the config file
  DOC

  @show_diff = false
  @bounce = false

  def use_parser(p)
    p.banner = usage("[options] <target>")
    p.on("-d", "--diff", "show a diff") { @show_diff = true }
    p.on("-b", "--bounce", "restart all containers") { @bounce = true }
  end

  def run(args)
    config = globals.config
    manager = Pod::Updater.new(STDOUT, globals.@remote_host, @bounce)
    configs = Array(Pod::Config::Container).new
    if args.empty?
      args = [":all"]
    end
    args.each do |target|
      configs.concat config.get_containers(target).map { |c| c[1] }
    end
    configs.each { |c| c.resolve_refs(config) }
    configs.each do |conf|
      conf.apply_overrides! remote: globals.@remote_host, detached: true
    end
    updates = manager.calculate_updates(configs)
    if @show_diff
      manager.print_changes(updates)
      if updates.any? &.actionable?
        print "update? [y/N] "
        if (inp = gets) && inp.chomp.downcase == "y"
          manager.update_containers(updates)
        end
      end
    else
      manager.update_containers(updates)
    end
  end
end

class EnterOptions
  include Pod::CLI::Subcommand
  CMD  = "enter"
  DESC = "run shell in container"
  DOCS = <<-DOC
  Run a shell in a container
  DOC

  @new_container = false

  def use_parser(p)
    p.banner = usage("[options] <target>")
    with_target(p)
    p.on("-n", "--new", "start a new container instead of checking for extisting one") { @new_container = true }
  end

  def run(args)
    entrypoint = @target
    Pod::Runner.new(globals.config, globals.@remote_host, false, STDOUT).enter(
      entrypoint, args, @new_container)
  end
end

class InitOptions
  include Pod::CLI::Subcommand
  CMD  = "init"
  DESC = "create new pod project in current directory"
  DOCS = <<-DOC
  Initialise a pod project in the currect directory
  DOC

  def use_parser(p)
    p.banner = usage("")
  end

  def run(args)
    Pod::Initializer.run
  end
end

class SecretsOptions
  include Pod::CLI::Subcommand
  CMD  = "secrets"
  DESC = "update secrets from config"
  DOCS = <<-DOC
  Update secrets!
  DOC

  def use_parser(p)
    p.banner = usage("[options] <target>")
    with_target(p)
  end

  def run(args)
    config = globals.config
    target = @target || config.defaults.update
    runner = Pod::Runner.new(config, globals.@remote_host, false, STDOUT)
    runner.update_secrets(target)
  end
end

class ScriptOptions
  include Pod::CLI::Subcommand
  CMD  = "script"
  DESC = "run a script"
  DOCS = <<-DOC
  run a script in a container
  DOC

  @type : String? = nil

  def use_parser(p)
    p.banner = usage("[options] <file> [flags]")
    p.on("-t", "--type=TYPE", "force a particular file type") { |t| @type = t }
  end

  def run(args)
    path = Path[PodOptions::SCRIPT_CONFIG].expand(home: true)
    unless File.exists? path
      raise Podman::Exception.new "Script config doesn't exist in #{PodOptions::SCRIPT_CONFIG}"
      exit 1
    end
    config = Pod::Scripter::Config.from_yaml(File.read(path))
    scripter = Pod::Scripter.new(config)
    scripter.exec(@type, args)
  end
end

class ReplOptions
  include Pod::CLI::Subcommand
  CMD  = "repl"
  DESC = "run a repl"
  DOCS = <<-DOC
  run a repl for a particular language in a container
  DOC

  def use_parser(p)
    p.banner = usage("[options] <file> [flags]")
    with_target(p)
  end

  def run(args)
    unless target = @target
      raise Podman::Exception.new("missing repl to start!")
    end
    config = Pod::Scripter::Config.from_yaml(File.read(Path[PodOptions::SCRIPT_CONFIG].expand(home: true)))
    scripter = Pod::Scripter.new(config)
    scripter.repl(target, args)
  end
end

class PodOptions
  SCRIPT_CONFIG = ENV["POD_SCRIPT_CONFIG"]? || "~/.config/pod/script.yaml"
  @config_path : String? = nil
  @remote_host : String? = nil
  @subcommand : Pod::CLI::Subcommand? = nil
  @config : Pod::Config::File? = nil
  @show_help = false

  def initialize(@args : Array(String))
    @option_parser = OptionParser.new
    use_parser(@option_parser)
    @option_parser.parse(@args)
  end

  def config
    @config ||= Pod::Config.load_config!(@config_path)
  end

  def use_parser(p)
    p.banner = "pod cli"
    p.on("-c", "--config=FILE", "config file path") { |c| @config_path = c }
    p.on("-r", "--remote=HOST", "remote host name") { |r| @remote_host = r }
    p.on("-v", "--version", "show version") do
      puts "pod version: #{Pod::VERSION} (#{Pod.build_info})"
      exit
    end
    p.on("-h", "--help", "show help") { @show_help = true }
    p.on("h", "show help") { @show_help = true }
    p.on("help", "show help") do
      @show_help = true
      subcommands(p)
    end
    subcommands(p)
    p.invalid_option do |flag|
      STDERR.puts "ERROR: #{flag} is not a valid option."
      STDERR.puts p
      exit(1)
    end
  end

  def subcommand(p, name, help, type)
    p.on(name, help) do
      unless @subcommand.nil?
        raise "double subcommands, wot"
      end
      @subcommand = cmd = type.new
      cmd.set_global_opts(self)
      cmd.use_parser(p)
    end
  end

  macro sub(target, type)
    subcommand({{ target }}, {{ type }}::CMD, {{ type }}::DESC, {{ type }})
  end

  def subcommands(p)
    sub p, RunOptions
    sub p, BuildOptions
    sub p, PushOptions
    sub p, UpdateOptions
    sub p, DiffOptions
    sub p, EnterOptions
    sub p, InitOptions
    sub p, SecretsOptions
    sub p, ScriptOptions
    sub p, ReplOptions
  end

  def show_help
    if sub = @subcommand
      puts sub.docs
    end
    puts @option_parser
  end

  def run(args)
    if @show_help
      show_help
    elsif sub = @subcommand
      begin
        # This is a hack, but an easy way to strip off the first arg
        unless sub.target.nil?
          args.shift
        end
        sub.run(args)
      rescue ex : Podman::Exception
        ex.print_message STDERR
        Log.notice(exception: ex) { "Pod failed" }
        exit 1
      rescue ex : ::Exception
        STDERR.puts ex.message
        Log.error(exception: ex) { "Unexpected exception" }
        exit 1
      end
    else
      show_help
    end
  end
end
