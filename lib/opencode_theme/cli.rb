require 'thor'
require 'yaml'
YAML::ENGINE.yamler = 'syck' if defined? Syck
require 'abbrev'
require 'base64'
require 'fileutils'
require 'json'
require 'filewatcher'
require 'launchy'
require 'mimemagic'


module OpencodeTheme
  class Cli < Thor
    include Thor::Actions

    IGNORE = %w(config.yml)
    DEFAULT_WHITELIST = %w(layout/ assets/ config/ snippets/ templates/)
    TIMEFORMAT = "%H:%M:%S"

    tasks.keys.abbrev.each do |shortcut, command|
      map shortcut => command.to_sym
    end
    
    #opencode configure apikey pass loja
    desc "configure API_KEY PASSWORD STORE THEME_ID", "generate a config file for the store to connect to"
    def configure(api_key=nil, password=nil, theme_id=nil)
      config = {:api_key => api_key, :password => password, :theme_id => theme_id}
      OpencodeTheme.config = config
      response = OpencodeTheme.check_config
      if response[:success]
        puts "response=>#{response.inspect}"
        config.merge!(:preview_url => response[:response]['url_preview'])

         create_file('config.yml', config.to_yaml, :force => true)
        say("Configuration [OK]", :green)
      else
        say("Configuration [FAIL]", :red)
      end
    end

    desc "upload FILE", "upload all theme assets to shop"
      method_option :quiet, :type => :boolean, :default => false
      def upload(*keys)
        assets = keys.empty? ? local_assets_list : keys
        assets.each do |asset|
          send_asset(asset, options['quiet'])
        end
        say("Done.", :green) unless options['quiet']
      end

 desc "remove FILE", "remove theme asset"
    method_option :quiet, :type => :boolean, :default => false
    def remove(*keys)
      keys.each do |key|
        delete_asset(key, options['quiet'])
      end
      say("Done.", :green) unless options['quiet']
    end

 desc "bootstrap API_KEY PASSWORD STORE THEME_NAME", "bootstrap with Timber to shop and configure local directory. Include master if you'd like to use the latest build for the theme"
    method_option :master, :type => :boolean, :default => false
    def bootstrap(api_key=nil, password=nil, store=nil, theme_name='default', theme_base='default')
      OpencodeTheme.config = {:api_key => api_key, :password => password, :store => store}
      check_config = OpencodeTheme.check_config
      if check_config[:success]
        say("Configuration [OK]", :green)
      else
        report_error(Time.now, "Configuration [FAIL]", check_config[:response])
        return
      end
puts "criou a config"

      response = OpencodeTheme.theme_new(theme_base, theme_name)
      puts "response=>#{response.inspect}"
      if response[:success]
        say("Create #{theme_name} theme on store [#{store}]", :green)
      else
        report_error(Time.now, "Could not create a new theme", response[:response])
        return
      end

      say("Creating directory named #{theme_name}", :green)
      empty_directory(theme_name)

      say("Saving configuration to #{theme_name}", :green)
      OpencodeTheme.config.merge!(theme_id: response[:response]['theme_id'], preview_url: response[:response]['preview'])
      create_file("#{theme_name}/config.yml", OpencodeTheme.config.to_yaml)

      say("Downloading #{theme_name} assets from Opencode")
      Dir.chdir(theme_name)
      download()
    end


    desc "download FILE", "download the shops current theme assets"
    method_option :quiet, :type => :boolean, :default => false
    method_option :exclude
    def download(*keys)
      puts "download=>#{keys.inspect}"
      assets = keys.empty? ? OpencodeTheme.asset_list : keys
puts "=>assets =>#{assets.inspect}"
      if options['exclude']
        assets = assets.delete_if { |asset| asset =~ Regexp.new(options['exclude']) }
      end
      puts "todos assets=>#{assets.inspect}"
      assets.each do |asset|
        download_asset(asset)
        say("#{OpencodeTheme.api_usage} Downloaded: #{asset}", :green) unless options['quiet']
      end
      say("Done.", :green) unless options['quiet']
    end

    desc "watch", "upload and delete individual theme assets as they change, use the --keep_files flag to disable remote file deletion"
    method_option :quiet, :type => :boolean, :default => false
    method_option :keep_files, :type => :boolean, :default => false
    def watch
      puts "111---->Watching current folder: #{Dir.pwd}"
      watcher do |filename, event|
        filename = filename.gsub("#{Dir.pwd}/", '')
puts "filename=>#{filename.inspect}"
        next unless local_assets_list.include?(filename)
        action = if [:changed, :new].include?(event)
          :send_asset
        elsif event == :delete
          :delete_asset
        else
          raise NotImplementedError, "Unknown event -- #{event} -- #{filename}"
        end

        send(action, filename, options['quiet'])
      end
    end

    desc "systeminfo", "print out system information and actively loaded libraries for aiding in submitting bug reports"
    def systeminfo
      ruby_version = "#{RUBY_VERSION}"
      ruby_version += "-p#{RUBY_PATCHLEVEL}" if RUBY_PATCHLEVEL
      puts "Ruby: v#{ruby_version}"
      puts "Operating System: #{RUBY_PLATFORM}"
      %w(Thor Listen HTTParty Launchy).each do |lib|
        require "#{lib.downcase}/version"
        puts "#{lib}: v" +  Kernel.const_get("#{lib}::VERSION")
      end
    end

    desc "open", "open the store in your browser"
    def open(*keys)
      if Launchy.open opencode_theme_url
        say("Done.", :green)
      end
    end

    protected

    def config
      @config ||= YAML.load_file 'config.yml'
    end

    private


    def notify_and_sleep(message)
      say(message, :red)
      OpencodeTheme.sleep
    end

    def binary_file?(path)
      puts "binary_file=>#{path}"
      !MimeMagic.by_path(path).text?
    end

    def opencode_theme_url
      config[:preview_url]
    end
    

    def send_asset(asset, quiet=false)
      puts "send_asset=>#{asset.inspect}"
      return unless valid?(asset)
      data = {:key => asset}
      xx = File.read("#{Dir.pwd}/#{asset}")
      content = File.read(asset)
      if binary_file?(asset) || OpencodeTheme.is_binary_data?(content)
        content = File.open(asset, "rb") { |io| io.read }
        data.merge!(:attachment => Base64.encode64(content))
      else
        data.merge!(:value => content)
      end
      response = show_during("[#{timestamp}] Uploading: #{asset}", quiet) do
        OpencodeTheme.send_asset(data)
      end
      if response.success?
        say("[#{timestamp}] Uploaded: #{asset}", :green) unless quiet
      else
        report_error(Time.now, "Could not upload #{asset}", response)
      end
    end

    def delete_asset(key, quiet=false)
      return unless valid?(key)
      response = show_during("[#{timestamp}] Removing: #{key}", quiet) do
        OpencodeTheme.delete_asset(key)
      end
      if response.success?
        say("[#{timestamp}] Removed: #{key}", :green) unless quiet
      else
        report_error(Time.now, "Could not remove #{key}", response)
      end
    end
    def watcher
      FileWatcher.new(Dir.pwd).watch() do |filename, event|
        yield(filename, event)
      end
    end

    def local_assets_list
      local_files.reject do |p|
        @permitted_files ||= (DEFAULT_WHITELIST | OpencodeTheme.whitelist_files).map{|pattern| Regexp.new(pattern)}
        @permitted_files.none? { |regex| regex =~ p } || OpencodeTheme.ignore_files.any? { |regex| regex =~ p }
      end
    end

    def local_files
      Dir.glob(File.join('**', '*')).reject do |f|
        File.directory?(f)
      end
    end

    def valid?(key)
    return true
    #  return true if DEFAULT_WHITELIST.include?(key.split('/').first + "/")
     # say("'#{key}' is not in a valid file for theme uploads", :yellow)
     # say("Files need to be in one of the following subdirectories: #{DEFAULT_WHITELIST.join(' ')}", :yellow)
     # false
    end
    def timestamp(time = Time.now)
      time.strftime(TIMEFORMAT)
    end
    
    def download_asset(key)
      puts "download_asset"
      return unless valid?(key)
      notify_and_sleep("Approaching limit of API permits. Naptime until more permits become available!") if OpencodeTheme.needs_sleep?
      asset = OpencodeTheme.get_asset(key)
      puts "dentro de download_asset===>#{asset.inspect}"
      unless asset['key']
        report_error(Time.now, "Could not download #{key}", asset)
        return
      end
      if asset['content']
        # For CRLF line endings
        content = asset['content'].gsub("\r", "")
        format = "w"
      elsif asset['attachment']
        content = Base64.decode64(asset['attachment'])
        format = "w+b"
      end
puts "criar diretorio=>#{key.inspect}"
file = key[1..key.length]
puts "criar file=>#{file.inspect}"

      FileUtils.mkdir_p(File.dirname(file))
      File.open(file, format) {|f| f.write content} if content
    end
   def show_during(message = '', quiet = false, &block)
      print(message) unless quiet
      result = yield
      print("\r#{' ' * message.length}\r") unless quiet
      result
    end

    def report_error(time, message, response)
      say("[#{timestamp(time)}] Error: #{message}", :red)
      say("Error Details: #{response}", :yellow)
    end

  end
end
