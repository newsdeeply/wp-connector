require 'faraday'

module WpCache
  extend ActiveSupport::Concern

  module ClassMethods

    #
    # Collect all class names in a class variable so that it can be accessed by the Rake task.
    #
    def included(base)
      @classes ||= []
      @classes << base.name
    end

    #
    # Returns an array WpCache classes.
    #
    def classes
      @classes
    end

    #
    # Schedules a `create_or_update` call to itself.
    #
    def schedule_create_or_update(wp_id, preview = false, request = nil, delay = 0.5)
      extra_info = request ? " after #{request.fullpath} -- #{request.body.read}" : ""
      Rails.logger.info("SCHEDULED by #{self.class}" + extra_info)
      if delay > 0
        WpApiWorker.perform_in(delay.seconds, self, wp_id, preview)
      else
        WpApiWorker.perform_async(self, wp_id, preview)
      end
    end

    def schedule_update_options
      WpApiWorker.perform_async(self)
    end

    #
    # Gets the content from the WP API, finds-or-creates a record for it,
    # and passes it the content by the `update_wp_cache` instance method.
    #
    def create_or_update(wp_type, wp_id, preview = false)
      return unless wp_id.is_a? Fixnum or wp_id.is_a? String
      maybe_preview_segment = (preview ? "preview/" : "")
      wp_json = get_from_wp_api "#{ wp_type }/#{ maybe_preview_segment }#{ wp_id }"
      # WP API will return a code if the route is incorrect or
      # the specified entry is none existant. If so return early.
      return if wp_json[0] and invalid_api_responses.include? wp_json[0]["code"]
      unscoped.where(wp_id: wp_id).first_or_initialize.update_wp_cache(wp_json)
    end

    def update_options
      wp_json = get_from_wp_api "options"
      # WP API will return a code if the route is incorrect or
      # the specified entry is none existant. If so return early.
      return if wp_json[0] and invalid_api_responses.include? wp_json[0]["code"]
      self.update_wp_cache(wp_json)
    end

    def create_or_update_all
      if paginated_models.include?(wp_type)
        create_or_update_all_paginated
      else
        create_or_update_all_non_paginated
      end
    end

    #
    # Gets all WP IDs for a class of WP content form the WP API,
    # finds-or-creates a record for it, and passes it the content by
    # the `update_wp_cache` instance method.
    # Removes records with unknown IDs.
    #
    # TODO (dunyakirkali) clean up
    def create_or_update_all_paginated
      page = 0
      ids = []
      max_page = (ENV['MAX_PAGE'].to_i == 0 ? 999 : ENV['MAX_PAGE'].to_i)
      while page < max_page do
        Rails.logger.info " page #{page}"
        wp_json = get_from_wp_api(wp_type, page)
        break if wp_json.empty?
        ids << wp_json.map do |json|
          wp_id = json['ID']
          unscoped.where(wp_id: wp_id).first_or_initialize.update_wp_cache(json)
          wp_id
        end
        page = page + 1
      end
      unscoped.where('wp_id NOT IN (?)', ids.flatten).destroy_all unless ids.empty?
    end

    # TODO (dunyakirkali) doc
    def create_or_update_all_non_paginated
      wp_json = get_from_wp_api(wp_type)
      ids = wp_json.map do |json|
        wp_id = json['ID']
        unscoped.where(wp_id: wp_id).first_or_initialize.update_wp_cache(json)
        wp_id
      end
      unscoped.where('wp_id NOT IN (?)', ids).destroy_all unless ids.empty?
    end

    #
    # Purge a cached piece of content, while logging any exceptions.
    #
    def purge(wp_id)
      unscoped.where(wp_id: wp_id).first!.destroy
    rescue
      logger.warn "Could not purge #{self} with id #{wp_id}, no record with that id was found."
    end

    def unpublish(wp_id)
      where(wp_id: wp_id).first!.update_attribute(:status, "draft")
    rescue
      logger.warn "Could not unpublish #{self} with id #{wp_id}, no record with that id was found."
    end


    private

    #
    # Convenience method for calling the WP API.
    #
    # TODO (cies): re-raise any connection errors with more intuitive names
    def get_from_wp_api(route, page = -1)

      # TODO (dunyakirkali) pass filter through args to get_from_wp_api
      # posts_per_page = (ENV['PER_PAGE'].to_i == -1 ? -1 : ENV['PER_PAGE'].to_i)
      base = WpConnector.configuration.wordpress_url

      if route.include?('executive_summaries')
        route = route.gsub 'executive_summaries', 'executive-summary'
      end

      unless paginated_models.include?(wp_type)
        url = "#{base}wp-json/wp/v2/#{route}"
      # else
      #   url = "#{base}wp-json/wp/v2/#{route}&filter[posts_per_page]=#{posts_per_page}&page=#{page}"
      end

      #binding.pry

      Rails.logger.info "We get next route: #{route}"
      Rails.logger.info "Current API call: #{url}"

      response = Faraday.get url

      unless response.success? || (response.status >= 500 && response.status <= 599)
        fail Exceptions::WpApiResponseError, "WP-API #{url} responded #{response.status} #{response.body}"
      end

      JSON.parse(response.body)
    end

    #
    # List of paginated models
    #
    def paginated_models
      models = WpConnector.configuration.wp_api_paginated_models
      if models.empty?
        Rails.logger.warn "Please specifiy WpConnector.configuration.wp_api_paginated_models, as the default is DEPRICATED"
        models = %w( articles news_articles pages media)
      end
      models
    end

    #
    # List of invalid api responses
    #
    # TODO (cies): refactor to WpCache::WP_API_ERROR_CODES
    def invalid_api_responses
      %w( json_no_route json_post_invalid_type json_user_cannot_read )
    end
  end
end
