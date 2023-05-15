require "inotify"

abstract class Watcher
  WATCHED_EVENTS = {
    Inotify::Event::Type::MODIFY,
    Inotify::Event::Type::DELETE,
    Inotify::Event::Type::DELETE_SELF,
    Inotify::Event::Type::MOVED_FROM,
    Inotify::Event::Type::MOVED_TO,
    Inotify::Event::Type::CREATE,
  }
  enum State
    Waiting
    Running
    Dirty
    Stopped
  end
  @watchers = Set(Inotify::Watcher).new
  @finished = Channel(Nil).new
  @lock = Mutex.new
  @state = State::Waiting

  def watch(dirs : Enumerable(String))
    dirs.each do |dir|
      @watchers << Inotify.watch(dir, recursive: true) do |event|
        next unless WATCHED_EVENTS.includes? event.type
        unless (path = event.path) && (name = event.name)
          Log.warn { "No path or name?" }
          next
        end
        next unless self.good_change? Path[path] / name
        Log.info { "Changed in #{dir}: #{event} (#{@state})" }
        @lock.synchronize do
          case @state
          when State::Waiting
            Log.info { "Starting" }
            @state = State::Running
            start
          when State::Running
            Log.info { "Marked dirty" }
            @state = State::Dirty
          when State::Dirty
            Log.info { "Even more dirty" }
          when State::Stopped
            Log.info { "I'm supposed to be stopped" }
          end
        end
      end
    end
    @finished.receive?
  end

  def start
    spawn do
      Log.info { "Running..." }
      run
      @lock.synchronize do
        if @state == State::Running
          @state = State::Waiting
        elsif @state == State::Dirty
          @state = State::Running
          start
        else
          Log.info { "Finished running and state was #{@state}" }
        end
      end
    end
  end

  def running?
    @lock.synchronize do
      return @state == State::Running
    end
  end

  abstract def run
  abstract def handle_interrupt

  def good_change?(path : Path) : Bool
    true
  end

  def interrupt
    @lock.synchronize do
      case @state
      when State::Waiting
        stop_internal
      when State::Running
        @state = State::Waiting
        handle_interrupt
      when State::Dirty
        handle_interrupt
        @state = State::Running
        start
      when State::Stopped
        Log.error { "I'm already stopped!" }
      end
    end
  end

  def stop
    @lock.synchronize do
      stop_internal
    end
  end

  private def stop_internal
    @state = State::Stopped
    @watchers.each &.close
    @finished.send nil
    @finished.close
  end
end
