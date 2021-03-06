require 'json'

module AdminUI
  class CC
    def initialize(config, logger)
      @config = config
      @logger = logger

      @caches = {}
      # These keys need to conform to their respective discover_x methods.
      # For instance applications conforms to discover_applications
      [:applications, :organizations, :spaces, :users_cc_deep, :users_uaa].each do |key|
        hash = { :semaphore => Mutex.new, :condition => ConditionVariable.new, :result => nil }
        @caches[key] = hash

        Thread.new do
          loop do
            schedule_discovery(key, hash)
          end
        end
      end
    end

    def applications
      result_cache(:applications)
    end

    def applications_count
      applications['items'].length
    end

    def applications_running_instances
      instances = 0
      applications['items'].each do |app|
        instances += app['instances'] if app['state'] == 'STARTED'
      end
      instances
    end

    def applications_total_instances
      instances = 0
      applications['items'].each do |app|
        instances += app['instances']
      end
      instances
    end

    def organizations
      result_cache(:organizations)
    end

    def organizations_count
      organizations['items'].length
    end

    def spaces
      result_cache(:spaces)
    end

    def spaces_auditors
      users_cc_deep = result_cache(:users_cc_deep)
      if users_cc_deep['connected']
        discover_spaces_auditors(users_cc_deep)
      else
        result
      end
    end

    def spaces_count
      spaces['items'].length
    end

    def spaces_developers
      users_cc_deep = result_cache(:users_cc_deep)
      if users_cc_deep['connected']
        discover_spaces_developers(users_cc_deep)
      else
        result
      end
    end

    def spaces_managers
      users_cc_deep = result_cache(:users_cc_deep)
      if users_cc_deep['connected']
        discover_spaces_managers(users_cc_deep)
      else
        result
      end
    end

    def users
      result_cache(:users_uaa)
    end

    def users_count
      users['items'].length
    end

    private

    def schedule_discovery(key, hash)
      key_string = key.to_s

      @logger.debug("[#{ @config.cloud_controller_discovery_interval } second interval] Starting CC #{ key_string } discovery...")

      result_cache = send("discover_#{ key_string }".to_sym)

      hash[:semaphore].synchronize do
        @logger.debug("Caching CC #{ key_string } data...")
        hash[:result] = result_cache
        hash[:condition].broadcast
        hash[:condition].wait(hash[:semaphore], @config.cloud_controller_discovery_interval)
      end
    end

    def result_cache(key)
      hash = @caches[key]
      hash[:semaphore].synchronize do
        hash[:condition].wait(hash[:semaphore]) while hash[:result].nil?
        hash[:result]
      end
    end

    def result(items = nil)
      if items.nil?
        {
          'connected' => false,
          'items'     => []
        }
      else
        {
          'connected' => true,
          'items'     => items
        }
      end
    end

    def discover_applications
      items = []
      get_cc('v2/apps').each do |app|
        items.push(app['entity'].merge(app['metadata']))
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_applications: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_organizations
      items = []
      get_cc('v2/organizations').each do |app|
        items.push(app['entity'].merge(app['metadata']))
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_organizations: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_spaces
      items = []
      get_cc('v2/spaces').each do |app|
        items.push(app['entity'].merge(app['metadata']))
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_spaces: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_spaces_auditors(users_deep)
      items = []
      users_deep['items'].each do |user_deep|
        guid = user_deep['metadata']['guid']

        user_deep['entity']['audited_spaces'].each do |space|
          items.push('user_guid'  => guid,
                     'space_guid' => space['metadata']['guid'])
        end
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_spaces_auditors: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_spaces_developers(users_deep)
      items = []
      users_deep['items'].each do |user_deep|
        guid = user_deep['metadata']['guid']

        user_deep['entity']['spaces'].each do |space|
          items.push('user_guid'  => guid,
                     'space_guid' => space['metadata']['guid'])
        end
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_spaces_developers: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_spaces_managers(users_deep)
      items = []
      users_deep['items'].each do |user_deep|
        guid = user_deep['metadata']['guid']

        user_deep['entity']['managed_spaces'].each do |space|
          items.push('user_guid'  => guid,
                     'space_guid' => space['metadata']['guid'])
        end
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_spaces_managers: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_users_cc_deep
      result(get_cc('v2/users?inline-relations-depth=1'))
    rescue => error
      @logger.debug("Error during discover_users_cc_deep: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def discover_users_uaa
      items = []
      get_uaa('Users').each do |user|
        emails = user['emails']
        groups = user['groups']
        meta   = user['meta']
        name   = user['name']

        authorities = []
        groups.each do |group|
          authorities.push(group['display'])
        end

        attributes = { 'active'        => user['active'],
                       'authorities'   => authorities.sort.join(', '),
                       'created'       => meta['created'],
                       'id'            => user['id'],
                       'last_modified' => meta['lastModified'],
                       'version'       => meta['version'] }

        attributes['email']      = emails[0]['value'] unless emails.nil? || emails.length == 0
        attributes['familyname'] = name['familyName'] unless name['familyName'].nil?
        attributes['givenname']  = name['givenName'] unless name['givenName'].nil?
        attributes['username']   = user['userName'] unless user['userName'].nil?

        items.push(attributes)
      end
      result(items)
    rescue => error
      @logger.debug("Error during discover_users_uaa: #{ error.inspect }")
      @logger.debug(error.backtrace.join("\n"))
      result
    end

    def get_cc(path)
      uri = "#{ @config.cloud_controller_uri }/#{ path }"

      resources = []
      loop do
        json = get(uri)
        resources.concat(json['resources'])
        next_url = json['next_url']
        return resources if next_url.nil?
        uri = "#{ @config.cloud_controller_uri }#{ next_url }"
      end

      resources
    end

    def get_uaa(path)
      info

      uri = "#{ @token_endpoint }/#{ path }"

      resources = []
      loop do
        json = get(uri)
        resources.concat(json['resources'])
        total_results = json['totalResults']
        start_index = resources.length + 1
        return resources unless total_results > start_index
        uri = "#{ @token_endpoint }/#{ path }?startIndex=#{ start_index }"
      end

      resources
    end

    def get(uri)
      recent_login = false
      if @token.nil?
        login
        recent_login = true
      end

      loop do
        response = Utils.http_get(@config, uri, nil, @token)
        if response.is_a?(Net::HTTPOK)
          return JSON.parse(response.body)
        elsif !recent_login && response.is_a?(Net::HTTPUnauthorized)
          login
          recent_login = true
        else
          fail "Unexected response code from get is #{ response.code }, message #{ response.message }"
        end
      end
    end

    def login
      info

      @token = nil

      response = Utils.http_post(@config,
                                 "#{ @token_endpoint }/oauth/token",
                                 "grant_type=password&username=#{ @config.uaa_admin_credentials_username }&password=#{ @config.uaa_admin_credentials_password }",
                                 'Basic Y2Y6')

      if response.is_a?(Net::HTTPOK)
        body_json = JSON.parse(response.body)
        @token = "#{ body_json['token_type'] } #{ body_json['access_token'] }"
      else
        fail "Unexpected response code from login is #{ response.code }, message #{ response.message }"
      end
    end

    def info
      return unless @token_endpoint.nil?

      response = Utils.http_get(@config, "#{ @config.cloud_controller_uri }/info")

      if response.is_a?(Net::HTTPOK)
        body_json = JSON.parse(response.body)

        @authorization_endpoint = body_json['authorization_endpoint']
        if @authorization_endpoint.nil?
          fail "Information retrieved from #{ url } does not include authorization_endpoint"
        end

        @token_endpoint = body_json['token_endpoint']
        if @token_endpoint.nil?
          fail "Information retrieved from #{ url } does not include token_endpoint"
        end
      else
        fail "Unable to fetch info from #{ url }"
      end
    end
  end
end
