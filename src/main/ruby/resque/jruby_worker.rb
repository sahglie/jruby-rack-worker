require 'resque' unless defined?(Resque::Worker)
require 'java'
require 'jruby'
require 'logger'

module Resque
  # Thread-safe worker usable with JRuby, adapts most of the methods designed
  # to be used in a process per worker env to behave safely in concurrent env.
  class JRubyWorker < Worker
    
    def initialize(*queues)
      super
      @cant_fork = true
    end
    
    # reserve changed since version 1.20.0
    RESERVE_ARG = instance_method(:reserve).arity > 0 # :nodoc
    
    # @see Resque::Worker#work
    def work(interval = 5.0, &block)
      interval = Float(interval)
      procline "Starting" # do not change $0
      startup
      
      loop do
        break if shutdown?
        
        if paused?
          procline "Paused"
          pause while paused? # keep sleeping while paused
        end
        
        if job = RESERVE_ARG ? reserve(interval) : reserve
          log "got: #{job.inspect}"
          job.worker = self
          run_hook :before_fork, job
          working_on job

          procline "Processing #{job.queue} since #{Time.now.to_i}"
          perform(job, &block)

          done_working
        else
          break if interval.zero?
          if RESERVE_ARG
            log! "Sleeping for #{interval} seconds"
            procline paused? ? "Paused" : "Waiting for #{@queues.join(',')}"
            sleep interval            
          else
            log! "Timed out after #{interval} seconds"
            procline paused? ? "Paused" : "Waiting for #{@queues.join(',')}"
          end
        end
      end

    ensure
      unregister_worker
    end
    
    # No forking with JRuby !
    # @see Resque::Worker#fork
    def fork # :nodoc
      @cant_fork = true
      nil # important due #work
    end

    # @see Resque::Worker#enable_gc_optimizations
    def enable_gc_optimizations # :nodoc
      nil # we're definitely not REE
    end
    
    # @see Resque::Worker#startup
    def startup
      # we do not register_signal_handlers
      prune_dead_workers
      run_hook :before_first_fork
      register_worker
      update_native_thread_name
    end

    # @see Resque::Worker#pause
    def pause
      # trap('CONT') makes no sense here
      sleep(1.0)
    end
    
    # @see Resque::Worker#pause_processing
    def pause_processing
      log "pausing job processing"
      @paused = true
    end
    
    # @see Resque::Worker#inspect
    def inspect
      "#<JRubyWorker #{to_s}>"
    end
    
    # @see Resque::Worker#to_s
    def to_s
      @to_s ||= "#{hostname}:#{pid}[#{thread_id}]:#{@queues.join(',')}".freeze
    end
    alias_method :id, :to_s
    
    # @see Resque::Worker#hostname
    def hostname
      java.net.InetAddress.getLocalHost.getHostName
    end
    
    # @see #worker_thread_ids
    def thread_id
      java.lang.Thread.currentThread.getName
    end
    
    # similar to the original pruning but accounts for thread-based workers
    # @see Resque::Worker#prune_dead_workers
    def prune_dead_workers
      all_workers = self.class.all
      known_workers = worker_thread_ids unless all_workers.empty?
      pids = nil, hostname = self.hostname
      all_workers.each do |worker|
        # thread name might contain ':' thus split it first :
        id = worker.id.split(/\[(.*?)\]/)
        thread = id.delete_at(1)
        host, pid, queues = id.join.split(':')
        next if host != hostname
        next if known_workers.include?(thread) && pid == self.pid.to_s
        # NOTE: allow flexibility of running workers :
        # 1. worker might run in another JVM instance
        # 2. worker might run as a process (with MRI)
        next if (pids ||= system_pids).include?(pid)
        log! "Pruning dead worker: #{worker}"
        worker.unregister_worker
      end
    end

    WORKER_THREAD_ID = 'worker'.freeze
    
    # returns worker thread names that supposely belong to the current application
    def worker_thread_ids
      thread_group = java.lang.Thread.currentThread.getThreadGroup
      thread_class = java.lang.Thread.java_class
      threads = java.lang.reflect.Array.newInstance(thread_class, thread_group.activeCount)
      thread_group.enumerate(threads)
      # NOTE: we shall check the name from $servlet_context.getServletContextName
      # but that's an implementation detail of the factory currently that threads
      # are named including their context name. thread grouping should be fine !
      threads.map do |thread| # a convention is to name threads as "worker" :
        thread && thread.getName.index(WORKER_THREAD_ID) ? thread.getName : nil
      end.compact
    end
    
    # Similar to Resque::Worker#worker_pids but without the worker.pid files.
    # Since this is only used to #prune_dead_workers it's fine to return PIDs
    # that have nothing to do with resque, it's only important that those PIDs
    # contain processed that are currently live on the system and perform work.
    # 
    # Thus the naive implementation to return all PIDs running within the OS 
    # (under current user) is acceptable.
    def system_pids
      pids = `ps -e -o pid`.split("\n")
      pids.delete_at(0) # PID (header)
      pids.each(&:'strip!')
    end
    require 'rbconfig'
    if RbConfig::CONFIG['host_os'] =~ /mswin|mingw/i
      require 'csv'
      def system_pids
        pids_csv = `tasklist.exe /FO CSV /NH` # /FI "PID gt 1000" 
        # sample output :
        # "System Idle Process","0","Console","0","16 kB"
        # "System","4","Console","0","228 kB"
        # "smss.exe","1056","Console","0","416 kB"
        # "csrss.exe","1188","Console","0","5,276 kB"
        # "winlogon.exe","1212","Console","0","4,708 kB"
        pids = CSV.parse(pids_csv).map! { |record| record[1] }
        pids.delete_at(0) # no CSV header thus first row nil
        pids
      end
    end
    
    protected
    
    # @see Resque::Worker#register_worker
    def register_worker
      outcome = super
      system_register_worker
      outcome
    end
    
    # @see Resque::Worker#unregister_worker
    def unregister_worker
      system_unregister_worker
      super
    end
    
    # @see Resque::Worker#procline
    def procline(string = nil)
      # do not change $0 as this method otherwise would ...
      if string.nil?
        @procline # and act as a reader if no argument given
      else
        log! @procline = "resque-#{Resque::Version}: #{string}"
      end
    end

    # Log a message to STDOUT if we are verbose or very_verbose.
    # @see Resque::Worker#log
    def log(message)
      if verbose
        logger.info "*** #{message}"
      elsif very_verbose
        time = Time.now.strftime('%H:%M:%S %Y-%m-%d')
        name = java.lang.Thread.currentThread.getName
        logger.debug "** [#{time}] #{name}: #{message}"
      end
    end
    
    public
    
    def logger
      # resque compatibility - stdout by default
      @logger ||= begin 
        logger = Logger.new(STDOUT)
        logger.level = Logger::WARN
        logger.level = Logger::INFO if verbose
        logger.level = Logger::DEBUG if very_verbose
        logger
      end
    end
    
    # We route log output through a logger 
    # (instead of printing directly to stdout).
    def logger=(logger)
      @logger = logger
    end
    
    private
    
    # so that we can later identify a "live" worker thread
    def update_native_thread_name
      thread = JRuby.reference(Thread.current)
      set_thread_name = Proc.new do |prefix, suffix|
        self.class.with_global_lock do
          count = self.class.system_registered_workers.size
          thread.native_thread.name = "#{prefix}##{count}#{suffix}"
        end
      end
      if ! name = thread.native_thread.name
        # "#{THREAD_ID}##{count}" :
        set_thread_name.call(WORKER_THREAD_ID, nil)
      elsif ! name.index(WORKER_THREAD_ID)
        # "#{name}(#{THREAD_ID}##{count})" :
        set_thread_name.call("#{name} (#{WORKER_THREAD_ID}", ')')
      end
    end
    
    WORKERS_KEY = 'resque.workers'.freeze
    
    # register a worked id globally (for this application)
    def system_register_worker # :nodoc
      self.class.with_global_lock do
        workers = self.class.system_registered_workers.push(self.id)
        self.class.store_global_property(WORKERS_KEY, workers.join(','))
      end
    end

    # unregister a worked id globally
    def system_unregister_worker # :nodoc
      self.class.with_global_lock do
        workers = self.class.system_registered_workers
        workers.delete(self.id)
        self.class.store_global_property(WORKERS_KEY, workers.join(','))
      end
    end
    
    # returns all registered worker ids
    def self.system_registered_workers # :nodoc
      workers = fetch_global_property(WORKERS_KEY)
      ( workers || '' ).split(',')
    end

    # low-level API probably worth moving out of here :
    
    if defined?($serlet_context) && $serlet_context

      def self.fetch_global_property(key) # :nodoc
        with_global_lock do
          return $serlet_context.getAttribute(key)
        end
      end

      def self.store_global_property(key, value) # :nodoc
        with_global_lock do
          if value.nil?
            $serlet_context.removeAttribute(key)
          else
            $serlet_context.setAttribute(key, value)
          end
        end
      end

      def self.with_global_lock(&block) # :nodoc
        $serlet_context.synchronized(&block)
      end
      
    else # no $servlet_context assume 1 app within server/JVM (e.g. mizuno)
      
      def self.fetch_global_property(key) # :nodoc
        with_global_lock do
          return java.lang.System.getProperty(key)
        end
      end

      def self.store_global_property(key, value) # :nodoc
        with_global_lock do
          if value.nil?
            java.lang.System.clearProperty(key)
          else
            java.lang.System.setProperty(key, value)
          end
        end
      end

      def self.with_global_lock(&block) # :nodoc
        java.lang.System.java_class.synchronized(&block)
      end
      
    end
    
  end
end
