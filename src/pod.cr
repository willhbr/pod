require "yaml"
require "./pod/*"
require "clim"
require "geode"

DEFAULT_CONFIG_FILE   = "pods.yaml"
EXAMPLE_CONTAINERFILE = "\
FROM alpine:latest
ENTRYPOINT sh
"

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
  if conf = load_config(file)
    return conf
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
        config.get_images(args.target).each do |name, image|
          args = image.to_command(remote: opts.remote)
          if opts.show
            puts "podman #{Process.quote(args)}"
          else
            status = Process.run(command: "podman", args: args,
              input: Process::Redirect::Close,
              output: Process::Redirect::Inherit,
              error: Process::Redirect::Inherit)
            unless status.success?
              fail "failed to build #{name}"
            end
          end
        end
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
        containers = config.get_containers(args.target)
        multiple = containers.size > 1
        detached = nil
        if multiple
          detached = true
        elsif opts.detach
          detached = true
        elsif opts.interactive
          detached = false
        end
        containers.each do |name, container|
          args = container.to_command(extra_args, detached: detached, remote: opts.remote)
          if opts.show
            puts "podman #{Process.quote(args)}"
          elsif multiple
            status = Process.run(command: "podman", args: args,
              input: Process::Redirect::Close,
              output: Process::Redirect::Inherit,
              error: Process::Redirect::Inherit)
            unless status.success?
              fail "failed to run #{name}"
            end
          else
            Process.exec(command: "podman", args: args)
          end
        end
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
        images = config.get_images(args.target)
        multiple = images.size > 1
        images.each do |name, image|
          unless tag = image.tag
            raise "can't push image with no tag: #{name}"
          end
          unless push = image.push
            raise "can't push image with no push destination: #{name}"
          end
          if opts.remote
            args = {"--remote=true", "--connection=#{opts.remote}", "push", tag, push}
          else
            args = {"push", tag, push}
          end
          if opts.show
            puts "podman #{Process.quote(args)}"
          elsif multiple
            status = Process.run(command: "podman", args: args,
              input: Process::Redirect::Close,
              output: Process::Redirect::Inherit,
              error: Process::Redirect::Inherit)
            unless status.success?
              fail "failed to run #{name}"
            end
          else
            Process.exec(command: "podman", args: args)
          end
        end
      end
    end
    sub "update" do
      desc "update a running container"
      usage "pod update [options]"
      option "-c CONFIG", "--config=CONFIG", type: String, desc: "Config file", default: DEFAULT_CONFIG_FILE
      option "-r REMOTE", "--remote=REMOTE", type: String, desc: "Remote host to use", required: false
      argument "target", type: String, desc: "target to run", required: false

      run do |opts, args|
        config = load_config!(opts.config)
        containers = config.get_containers(args.target)
        manager = Podman::Manager.new("podman") do |config|
          config.to_command(cmd_args: nil, detached: true, remote: opts.remote)
        end
        manager.update_containers(containers.map { |c| c[1] })
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
        config = Config::File.new(Config::Defaults.new("example", "example"))
        config.images["example"] = Config::Image.new("Containerfile", "pod-example:latest")
        container = Config::Container.new("pod-example", "pod-example:latest")
        container.cmd_args << "sh"
        config.containers["example"] = container
        File.open(DEFAULT_CONFIG_FILE, "w") { |f| config.to_yaml(f) }
        unless File.exists? "Containerfile"
          File.write "Containerfile", EXAMPLE_CONTAINERFILE
        end
        puts "Initialised pod config files in #{File.basename(Dir.current)}"
      end
    end
  end
end

Log.setup do |l|
  l.stderr
end

CLI.start(ARGV)
