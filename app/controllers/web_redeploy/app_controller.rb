class WebRedeploy::AppController < ApplicationController

  layout false

  before_action :authorize_user, except: [:version_info]

  @@user_results ||= {}

  def database_statistics
    case ActiveRecord::Base.connection.class.to_s
    when "ActiveRecord::ConnectionAdapters::MysqlAdapter"
      db_name = Rails.configuration.database_configuration[Rails.env]["database"]
      sql = "SELECT table_name AS name, table_rows, data_length, index_length FROM information_schema.TABLES  WHERE table_schema = '#{db_name}' ORDER BY (data_length + index_length) DESC;"
      @table_data = ActiveRecord::Base.connection.execute(sql).map do |r|
        { name: r[0], rows: r[1], data_size: r[2], index_size: r[3] }
      end
    when "ActiveRecord::ConnectionAdapters::SQLite3Adapter"
      @table_data = "Not implemented for SQLite3" 
    end
  end

  def sanity_check
    @alerts = WebRedeploy::System.sanity_check
  end

  def code_environments
    # @config = {
    #   production: ["https://myyevo.com", "vibeoffice.com"],
    #   stage: ["avon.vibeoffice.com", "mannatech.vibeoffice.com", "qsciences.vibeoffice.com", "tsfl.vibeoffice.com",
    #     "herbalife.vibeoffice.com","nsp.vibeoffice.com","forevergreen.vibeoffice.com", "visalus.vibeoffice.com","yevo.vibeofficestage.com"],
    #   development: ["67.208.128.157", "branch-1-0.vibeoffice.com", "vibeofficestage.com", "127.0.0.1:3000"]
    # }
    # puts "\n\n\n\n"
    # puts @config.to_yaml
    # puts "\n\n\n\n"
    @config = (YAML.load_file("#{ENV['HOME']}/.code_environments.yml") rescue {}) || {}
    @config[:local] = ["http://localhost"]
    regenerate_diffs = (params[:regenerate_diffs] != "false")
    show_results = (params[:results] == "true")

    data = @@user_results[get_current_user]
    if show_results && data.present?
      @command = data[:command]
      @command_results = data[:command_results]
      @exit_status = data[:exit_status]
      @log_file = data[:log_file]
    end
    @restart_info = WebRedeploy::System.puma_restart_status
    @log_file = @restart_info[:log_file] if @restart_info.present? && @log_file.blank?

    environments = @config.keys
    @results = {}
    threads = []

    environments.each do |e|
      @results[e] = {}
      threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          _lookup_code_environment(e, regenerate_diffs)
        end
      end
    end
    threads.each{|t| t.join}
    render :code_environments
  end

  def pull_code
    command, command_results, exit_status = WebRedeploy::System.pull_code
    Rails.logger.info("")
    Rails.logger.info("")
    Rails.logger.info("pull_code() RESULTS:")
    Rails.logger.info("             command: #{command}")
    Rails.logger.info("             command_results: #{command_results}")
    Rails.logger.info("             exit_status: #{exit_status}")
    Rails.logger.info("")
    Rails.logger.info("")
    @@user_results[get_current_user] = { command: command, command_results: command_results, exit_status: exit_status }
    redirect_to web_redeploy.code_environments_path(regenerate_diffs: false)
  end

  def switch_branch
    WebRedeploy::System.switch_branch(params[:new_branch])
    redirect_to web_redeploy.code_environments_path(results: true)
  end



  def phased_restart
    command, log_file = WebRedeploy::System.phased_restart
    Rails.logger.info("")
    Rails.logger.info("")
    Rails.logger.info("phased_restart RESULTS:")
    Rails.logger.info("             command: #{command}")
    Rails.logger.info("             log_file: #{log_file}")
    Rails.logger.info("")
    Rails.logger.info("")
    @@user_results[get_current_user] = { command: command, log_file: log_file }
    redirect_to web_redeploy.code_environments_path(results: true)
  end

  def restart_resque_tasks
    messages  = WebRedeploy::System.restart_resque_tasks
    redirect_to :back, notice: messages.join("<br/>")
  end

  def restart_rules_engine
    messages  = WebRedeploy::System.restart_rules_engine
    redirect_to :back, notice: messages.join("<br/>")
  end

  def puma_server_processes
    @data = WebRedeploy.puma_server_processes
    respond_to do |format|
      format.js {}
      format.json {render json: @data}
    end
  end

  def bundle_install
    command, command_results, exit_status = WebRedeploy::System.bundle_install
    @@user_results[get_current_user] = { command: command, command_results: command_results, exit_status: exit_status }
    redirect_to web_redeploy.code_environments_path(results: true)
  end

  def tail_log
    params[:log_file] ||= "#{Rails.root}/log/#{Rails.env}.log"
    log_file_full_path = params[:log_file]
    lines = params[:lines].presence || 1024
    detect_end_strategy = params[:detect_end_strategy].presence || nil
    @grep = params[:grep]
    if @grep.present?
      results = `tail -#{lines * 10} #{ log_file_full_path } | grep '#{@grep}'`
      @lines = results.split(/\n/)[0,lines].reverse if request.format == :json
    else
      results = `tail -#{lines} #{ log_file_full_path }`
      @lines = results.split(/\n/).reverse if request.format == :json
    end
    data = { lines: @lines, success: "unknown" }
    if detect_end_strategy == "async_command"
      # see WebRedeploy::System.run_async_console_command
      if results.index("Execution completed without errors")
        data[:success] = "true"
      elsif results.index("ERROR: Execution failed with EXIT_STATUS")
        data[:success] = "false"
      end
    end
    respond_to do |wants|
      wants.html{ render }
      wants.json{ render(:json => data) }
    end
  end

  def version_info
    include_diffs = (params[:diffs] != "false")
    render :status => 200, json: WebRedeploy::System.build_version_info(include_diffs)
  end


  private
  def _lookup_code_environment(e, regenerate_diffs = true)
    @config[e].each do |server|
      if e == :local
        @results[e][server] = WebRedeploy::System.build_version_info(regenerate_diffs).with_indifferent_access
        Rails.logger.info ""
        Rails.logger.info "  Using local build_version_info: #{@results[e][server]}"
        Rails.logger.info ""
      else
        url = (server.start_with?("http")) ? server : "http://#{server}"
        service_url = "#{url}/api/v1/version_info"
        Rails.logger.debug "_lookup_code_environment calling: #{service_url}"
        begin
          response = HTTParty.get(service_url, timeout: 5)
          results = JSON.parse(response.body) rescue nil
          @results[e][server] = results
        rescue Exception => ex
          Rails.logger.error "Error looking up [#{service_url}]: #{ex.message}"
          @results[e][server] = {}
        end
      end
    end
  end

  def authorize_user 
    WebRedeploy.authorize_user.call(get_current_user)
  end

  def get_current_user 
    defined?(::Devise) ? current_user : :anonymous_coward
  end

end