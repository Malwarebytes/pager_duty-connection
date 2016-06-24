require 'faraday'
require 'faraday_middleware'
require 'active_support'
require 'active_support/core_ext'
require 'active_support/time_with_zone'

module PagerDuty

  class Connection
    attr_accessor :connection
    attr_accessor :api_version

    class FileNotFoundError < RuntimeError
    end

    class ApiError < RuntimeError
    end

    class RaiseFileNotFoundOn404 < Faraday::Middleware
      def call(env)
        response = @app.call env
        if response.status == 404
          raise FileNotFoundError, response.env[:url].to_s
        else
          response
        end
      end
    end

    class RaiseApiErrorOnNon200 < Faraday::Middleware
      def call(env)
        response = @app.call env
        unless [200, 201, 204].include?(response.status)
          url = response.env[:url].to_s
          message = "Got HTTP #{response['status']} back for #{url}"
          if error = response.body['error']
            # TODO May Need to check error.errors too
            message += "\n#{error.to_hash}"
          end

          raise ApiError, message
        else
          response
        end
      end
    end

    class ConvertTimesParametersToISO8601 < Faraday::Middleware
      TIME_KEYS = [:since, :until]
      def call(env)

        body = env[:body]
        TIME_KEYS.each do |key|
          if body.has_key?(key)
            body[key] = body[key].iso8601 if body[key].respond_to?(:iso8601)
          end
        end

        response = @app.call env
      end
    end

    class ParseTimeStrings < Faraday::Response::Middleware
      TIME_KEYS = %w(
        at
        created_at
        created_on
        end
        end_time
        last_incident_timestamp
        last_status_change_on
        rotation_virtual_start
        start
        started_at
        start_time
      )

      OBJECT_KEYS = %w(
        alert
        entry
        incident
        log_entry
        maintenance_window
        note
        override
        service
      )

      NESTED_COLLECTION_KEYS = %w(
        acknowledgers
        assigned_to
        pending_actions
      )

      def parse(body)
        case body
        when Hash, ::Hashie::Mash
          OBJECT_KEYS.each do |key|
            object = body[key]
            parse_object_times(object) if object

            collection_key = key.pluralize
            collection = body[collection_key]
            parse_collection_times(collection) if collection
          end

          body
        else
          raise "Can't parse times of #{body.class}: #{body}"
        end
      end

      def parse_collection_times(collection)
        collection.each do |object|
          parse_object_times(object)

          NESTED_COLLECTION_KEYS.each do |key|
            object_collection = object[key]
            parse_collection_times(object_collection) if object_collection
          end
        end
      end

      def parse_object_times(object)
        time = Time.zone ? Time.zone : Time

        TIME_KEYS.each do |key|
          if object.has_key?(key) && object[key].present?
            object[key] = time.parse(object[key])
          end
        end
      end
    end

    def initialize(token, api_version = 2)
      @api_version = api_version
      @connection = Faraday.new do |conn|
        conn.url_prefix = "https://api.pagerduty.com/"

        # use token authentication: https://v2.developer.pagerduty.com/docs/authentication
        conn.token_auth token

        conn.use RaiseApiErrorOnNon200
        conn.use RaiseFileNotFoundOn404

        conn.use ConvertTimesParametersToISO8601

        # use json
        conn.request :json

        # json back, mashify it
        conn.use ParseTimeStrings
        conn.response :mashify
        conn.response :json

        conn.adapter  Faraday.default_adapter
      end
    end

    def get(path, options = {})
      # paginate anything being 'get'ed, because the offset/limit isn't intutive
      page = (options.delete(:page) || 1).to_i
      limit = (options.delete(:limit) || 100).to_i
      offset = (page - 1) * limit

      run_request(:get, path, options.merge(:offset => offset, :limit => limit))
    end

    def put(path, options = {})
      run_request(:put, path, options)
    end

    def post(path, options = {})
      run_request(:post, path, options)
    end

    def delete(path, options = {})
      run_request(:delete, path, options)
    end

    def run_request(method, path, options)
      path = path.gsub(/^\//, '') # strip leading slash, to make sure relative things happen on the connection
      headers = nil
      response = connection.run_request(method, path, options, headers)
      response.body
    end

  end
end
