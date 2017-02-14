module Stormpath
  class DataStore
    include Stormpath::Http
    include Stormpath::Util::Assert

    DEFAULT_SERVER_HOST = 'api.stormpath.com'.freeze
    DEFAULT_API_VERSION = 1
    DEFAULT_BASE_URL = 'https://' + DEFAULT_SERVER_HOST + '/v' + DEFAULT_API_VERSION.to_s
    HREF_PROP_NAME = Stormpath::Resource::Base::HREF_PROP_NAME

    CACHE_REGIONS = %w(applications directories accounts groups groupMemberships accountMemberships
                       tenants customData provider providerData).freeze

    attr_reader :client, :request_executor, :cache_manager, :api_key, :base_url

    def initialize(request_executor, api_key, cache_opts, client, base_url = nil)
      assert_not_nil request_executor, 'RequestExecutor cannot be null.'

      @request_executor = request_executor
      @api_key = api_key
      @client = client
      @base_url = base_url || DEFAULT_BASE_URL
      initialize_cache(cache_opts)
    end

    def initialize_cache(cache_opts)
      @cache_manager = Stormpath::Cache::CacheManager.new
      regions_opts = cache_opts[:regions] || {}
      CACHE_REGIONS.each do |region|
        region_opts = regions_opts[region.to_sym] || {}
        region_opts[:store] ||= cache_opts[:store]
        region_opts[:store_opts] ||= cache_opts[:store_opts]
        @cache_manager.create_cache(region, region_opts)
      end
    end

    def instantiate(clazz, properties = {})
      clazz.new(properties, client)
    end

    def get_resource(href, clazz, query = nil)
      q_href = qualify href

      data = execute_request('get', q_href, nil, query)

      clazz = clazz.call(data) if clazz.respond_to? :call

      instantiate(clazz, data.to_hash)
    end

    def create(parent_href, resource, return_type, options = {})
      # TODO: assuming there is no ? in url
      parent_href = "#{parent_href}?#{URI.encode_www_form(options)}" unless options.empty?

      save_resource(parent_href, resource, return_type).tap do |returned_resource|
        if resource.is_a?(return_type)
          resource.set_properties(returned_resource.properties)
        end
      end
    end

    def save(resource, clazz = nil)
      assert_not_nil(resource, 'resource argument cannot be null.')
      assert_kind_of(
        Stormpath::Resource::Base,
        resource,
        'resource argument must be instance of Stormpath::Resource::Base'
      )
      href = resource.href
      assert_not_nil(href, 'href or resource.href cannot be null.')
      assert_true(
        !href.empty?,
        'save may only be called on objects that have already been persisted'\
        ' (i.e. they have an existing href).'
      )

      href = qualify(href)

      clazz ||= resource.class

      save_resource(href, resource, clazz).tap do |return_value|
        resource.set_properties(return_value)
      end
    end

    def delete(resource, property_name = nil)
      assert_not_nil(resource, 'resource argument cannot be null.')
      assert_kind_of(
        Stormpath::Resource::Base,
        resource,
        'resource argument must be instance of Stormpath::Resource::Base'
      )

      href = resource.href
      href += "/#{property_name}" if property_name
      href = qualify(href)

      execute_request('delete', href)
      clear_cache_on_delete(href)
      nil
    end

    def execute_raw_request(href, body, klass)
      request = Request.new('POST', href, nil, {}, body.to_json, @api_key)
      apply_default_request_headers(request)
      response = @request_executor.execute_request(request)
      result = !response.body.empty? ? MultiJson.load(response.body) : ''

      if response.error?
        error = Stormpath::Resource::Error.new(result)
        raise Stormpath::Error, error
      end

      cache_walk(result)
      instantiate(klass, result)
    end

    private

    def qualify(href)
      @qualifier ||= HrefQualifier.new(base_url)
      @qualifier.qualify(href)
    end

    def execute_request(http_method, href, resource = nil, query = nil)
      if http_method == 'get' && (cache = cache_for href)
        cached_result = cache.get(href)
        return cached_result if cached_result
      end

      body = extract_body_from_resource(resource)

      request = Request.new(http_method, href, query, {}, body, @api_key)

      if resource.try(:form_data?)
        apply_form_data_request_headers(request)
      else
        apply_default_request_headers(request)
      end

      response = @request_executor.execute_request(request)

      result = !response.body.empty? ? MultiJson.load(response.body) : ''

      if response.error?
        error = Stormpath::Resource::Error.new(result)
        raise Stormpath::Error, error
      end

      if resource.is_a?(Stormpath::Provider::AccountAccess)
        is_new_account = response.http_status == 201
        result = { is_new_account: is_new_account, account: result }
      end

      return if http_method == 'delete'

      if result[HREF_PROP_NAME] && !resource_is_saml_mapping_rules?(resource) && !user_info_mapping_rules?(resource)
        cache_walk result
      else
        result
      end
    end

    def clear_cache_on_delete(href)
      if href =~ custom_data_delete_field_url_regex
        href = href.split('/')[0..-2].join('/')
      end
      clear_cache(href)
    end

    def custom_data_delete_field_url_regex
      /#{base_url}\/(accounts|groups)\/\w+\/customData\/\w+[\/]{0,1}$/
    end

    def clear_cache(href)
      cache = cache_for(href)
      cache.delete(href) if cache
    end

    def cache_walk(resource)
      assert_not_nil(resource[HREF_PROP_NAME], "resource must have 'href' property")
      items = resource['items']

      if items # collection resource
        resource['items'] = items.map do |item|
          cache_walk(item)
          { HREF_PROP_NAME => item[HREF_PROP_NAME] }
        end
      else     # single resource
        resource.each do |attr, value|
          next unless value.is_a?(Hash) && value[HREF_PROP_NAME]
          walked = cache_walk(value)
          resource[attr] = { HREF_PROP_NAME => value[HREF_PROP_NAME] }
          resource[attr]['items'] = walked['items'] if walked['items']
        end
        cache(resource) if resource.length > 1
      end
      resource
    end

    def cache(resource)
      cache = cache_for(resource[HREF_PROP_NAME])
      cache.put(resource[HREF_PROP_NAME], resource) if cache
    end

    def cache_for(href)
      @cache_manager.get_cache(region_for(href))
    end

    def region_for(href)
      return nil if href.nil?
      region = if href.include?('/customData')
                 href.split('/')[-1]
               else
                 href.split('/')[-2]
               end
      CACHE_REGIONS.include?(region) ? region : nil
    end

    def apply_default_request_headers(request)
      request.http_headers.store('Accept', 'application/json')
      apply_default_user_agent(request)

      if request.body && !request.body.empty?
        request.http_headers.store('Content-Type', 'application/json')
      end
    end

    def apply_form_data_request_headers(request)
      request.http_headers.store('Content-Type', 'application/x-www-form-urlencoded')
      apply_default_user_agent(request)
    end

    def apply_default_user_agent(request)
      request.http_headers.store(
        'User-Agent', 'stormpath-sdk-ruby/' + Stormpath::VERSION +
        " ruby/#{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}" \
        ' ' + Gem::Platform.local.os.to_s + '/' + Gem::Platform.local.version.to_s
      )
    end

    def save_resource(href, resource, return_type)
      assert_not_nil(resource, 'resource argument cannot be null.')
      assert_not_nil(return_type, 'returnType class cannot be null.')
      assert_kind_of(
        Stormpath::Resource::Base,
        resource,
        'resource argument must be instance of Stormpath::Resource::Base'
      )

      q_href = qualify(href)
      clear_cache_on_save(resource)
      response = execute_request('post', q_href, resource)
      instantiate(return_type, parse_response(response))
    end

    def parse_response(response)
      return {} if response.is_a?(String) && response.blank?
      response.to_hash
    end

    def clear_cache_on_save(resource)
      if resource.is_a?(Stormpath::Resource::CustomDataStorage)
        clear_custom_data_cache_on_custom_data_storage_save(resource)
      elsif resource.is_a?(Stormpath::Resource::AccountStoreMapping)
        clear_application_cache_on_account_store_save(resource)
      end
    end

    def clear_custom_data_cache_on_custom_data_storage_save(resource)
      if resource.dirty_properties.key?('customData') && (resource.new? == false)
        cached_href = resource.href + '/customData'
        clear_cache(cached_href)
      end
    end

    def clear_application_cache_on_account_store_save(resource)
      if resource.new?
        if resource.default_account_store? == true || resource.default_group_store? == true
          clear_cache(resource.application.href)
        end
      else
        if !resource.dirty_properties['isDefaultAccountStore'].nil? || !resource.dirty_properties['isDefaultGroupStore'].nil?
          clear_cache(resource.application.href)
        end
      end
    end

    def extract_body_from_resource(resource)
      return if resource.nil?
      form_data = resource.try(:form_data?)

      if form_data
        form_request_parse(resource)
      else
        MultiJson.dump(to_hash(resource))
      end
    end

    def form_request_parse(resource)
      URI.encode_www_form(resource.form_properties.to_a)
    end

    def to_hash(resource)
      {}.tap do |properties|
        resource.get_dirty_property_names.each do |name|
          ignore_camelcasing = resource_is_custom_data(resource, name)
          property = resource.get_property name, ignore_camelcasing: ignore_camelcasing

          # Special use cases are with Custom Data, Provider and ProviderData, their hashes should not be simplified
          # As of the implementation for MFA, Phone resource is added too, as well ass config for LDAP
          if property.is_a?(Hash) && !resource_nested_submittable(resource, name) && name != 'items' && name != 'phone' && name != 'config'
            property = to_simple_reference(name, property)
          end

          if name == 'items' && resource_is_saml_mapping_rules?(resource) ||
             name == 'items' && user_info_mapping_rules?(resource)
            property = property.map do |item|
              item.transform_keys { |key| key.to_s.camelize(:lower).to_sym }
            end
          end

          # TODO: refactor transforming of keys in the to_hash method
          # Suggestion: Extract this logic into a service
          if name == 'config' && resource_is_agent_config?(resource)
            property = deep_transform_keys(property) { |key| key.to_s.camelize(:lower).to_sym }
          end

          properties.store(name, property)
        end
      end
    end

    def to_simple_reference(property_name, hash)
      assert_true(
        hash.key?(HREF_PROP_NAME),
        "Nested resource '#{property_name}' must have an 'href' property."
      )

      href = hash[HREF_PROP_NAME]

      { HREF_PROP_NAME => href }
    end

    def deep_transform_keys(property, &block)
      result = {}
      property.each do |key, value|
        result[yield(key)] = value.is_a?(Hash) ? deep_transform_keys(value, &block) : value
      end
      result
    end

    def resource_nested_submittable(resource, name)
      ['provider', 'providerData', 'accountStore'].include?(name) ||
        resource_is_custom_data(resource, name) ||
        resource_is_application_web_config(resource, name)
    end

    def resource_is_custom_data(resource, name)
      resource.is_a?(Stormpath::Resource::CustomData) || name == 'customData'
    end

    def resource_is_application_web_config(resource, name)
      resource.is_a?(Stormpath::Resource::ApplicationWebConfig) &&
        Stormpath::Resource::ApplicationWebConfig::ENDPOINTS.include?(name.underscore.to_sym)
    end

    def resource_is_saml_mapping_rules?(resource)
      resource.is_a?(Stormpath::Resource::AttributeStatementMappingRules)
    end

    def user_info_mapping_rules?(resource)
      resource.is_a?(Stormpath::Resource::UserInfoMappingRules)
    end

    def resource_is_agent_config?(resource)
      resource.is_a?(Stormpath::Resource::Agent)
    end
  end
end
