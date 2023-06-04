require "yaml"
require "./pod/*"
require "clim"
require "geode"
require "ecr"

DEFAULT_CONFIG_FILE = "pods.yaml"

def fail(msg) : NoReturn
  puts msg
  exit 1
end

def load_config(file) : Config::File?
  paths = Path[Dir.current].parents
  paths << Path[Dir.current]
  paths.reverse.each do |path|
    Dir.cd path
    target = path / (file || DEFAULT_CONFIG_FILE)
    if File.exists? target
      return Config::File.from_yaml(File.read(target))
    end
  end
end

def load_config!(file) : Config::File
  begin
    if conf = load_config(file)
      return conf
    end
  rescue ex : YAML::ParseException
    fail "Failed to parse config file: #{ex.message}"
  end

  fail "Config file #{file || DEFAULT_CONFIG_FILE} does not exist"
end

def run_podman(args, remote = nil)
  if remote
    a = ["--remote=true", "--connection=#{remote}"]
    a.concat(args)
  else
    a = args
  end
  Process.exec(command: "podman", args: a)
end

class CLI < Clim
  main do
    desc "Pod CLI"
    usage "pod [sub_command] [arguments]"
    run do |opts, args|
      puts opts.help_string
      if conf = load_config(nil)
        puts "pod build => pod build #{conf.defaults.build}" if conf.defaults.build
        puts "pod run => pod run #{conf.defaults.build}" if conf.defaults.run
        puts "pod update => pod run #{conf.defaults.update}" if conf.defaults.update
        puts
        puts "pod build #{conf.images.keys.join(", ")}" unless conf.images.size.zero?
        puts "pod run #{conf.containers.keys.join(", ")}" unless conf.containers.size.zero?
        puts
        puts "pod build|run :all,#{conf.groups.keys.join(", ")}" unless conf.groups.size.zero?
      end
    end
    sub "build" do
      desc "build an image"
      usage "pod build [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to build", required: false

      run do |opts, args|
        config = load_config!(opts.config)
        actuator = Actuator.new(config, opts.remote, opts.show, STDOUT)
        actuator.build(args.target)
      end
    end
    sub "run" do
      desc "run a container"
      usage "pod run [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-d", "--detach", type: Bool, desc: "Run container detached", default: false
      option "-i", "--interactive", type: Bool, desc: "Run container interactive", default: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        extra_args = args.argv.skip_while { |a| a != "--" }.to_a
        if extra_args.empty?
          extra_args = nil
        else
          extra_args = extra_args[1...]
        end
        config = load_config!(opts.config)
        if opts.detach
          detached = true
        elsif opts.interactive
          detached = false
        else
          detached = nil
        end
        Actuator.new(config, opts.remote, opts.show, STDOUT).run(args.target, detached, extra_args)
      end
    end
    sub "push" do
      desc "push an image to a registry"
      usage "pod push [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-s", "--show", type: Bool, desc: "Show command only", default: false
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to push", required: false

      run do |opts, args|
        config = load_config!(opts.config)
        Actuator.new(config, opts.remote, opts.show, STDOUT).push(args.target)
      end
    end
    sub "update" do
      desc "update a running container"
      usage "pod update [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      option "-d", "--diff", type: Bool, desc: "Show a diff", default: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = load_config!(opts.config)
        containers = config.get_containers(args.target || config.defaults.update)
        manager = Podman::Manager.new("podman", STDOUT) do |config|
          config.to_command(cmd_args: nil, detached: true, remote: opts.remote)
        end
        configs = containers.map { |c| c[1] }
        if opts.diff
          if manager.diff_containers(configs)
            print "update? [y/N] "
            if (inp = gets) && inp.chomp.downcase == "y"
              manager.update_containers(configs)
            end
          end
        else
          manager.update_containers(configs)
        end
      end
    end
    sub "diff" do
      desc "preview updates to running containers"
      usage "pod diff [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = load_config!(opts.config)
        containers = config.get_containers(args.target || config.defaults.update)
        manager = Podman::Manager.new("podman", STDOUT) do |config|
          config.to_command(cmd_args: nil, detached: true, remote: opts.remote)
        end
        configs = containers.map { |c| c[1] }
        manager.diff_containers(configs)
      end
    end
    sub "shell" do
      desc "run a shell in a container"
      usage "pod shell <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false

      run do |opts, args|
        run_podman({"exec", "-it", args.target, "sh", "-c",
                    "if which bash > /dev/null 2>&1; then bash; else sh; fi"}, remote: opts.remote)
      end
    end
    sub "attach" do
      desc "attach to a container"
      usage "pod attach <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      run do |opts, args|
        run_podman({"attach", args.target}, remote: opts.remote)
      end
    end
    sub "logs" do
      desc "show logs from a container"
      usage "pod logs <container>"
      argument "target", type: String, desc: "target to run in", required: true
      option "-f FOLLOW", "--follow=FOLLOW", type: Bool, desc: "follow logs", default: true
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false

      run do |opts, args|
        run_podman({"logs", "--follow=#{opts.follow}", args.target}, remote: opts.remote)
      end
    end
    sub "init" do
      desc "initialise a config file"
      usage "pod init"

      run do |opts, args|
        project = Path[Dir.current].basename
        unless File.exists? DEFAULT_CONFIG_FILE
          File.open(DEFAULT_CONFIG_FILE, "w") do |f|
            ECR.embed("src/template/pods.yaml", f)
          end
        end
        unless File.exists? "Containerfile.dev"
          File.write "Containerfile.dev", ECR.render("src/template/Containerfile.dev")
        end
        unless File.exists? "Containerfile.prod"
          File.write "Containerfile.prod", ECR.render("src/template/Containerfile.prod")
        end
        puts "Initialised pod config files in #{project}."
        puts "Please edit to taste."
      end
    end
  end
end

Log.setup do |l|
  l.stderr
end

CLI.start(ARGV)
