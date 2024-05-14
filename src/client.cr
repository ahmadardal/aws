require "http"
require "awscr-signer"
require "db/pool"

require "./aws"

# It doesn't handle `Connection: keep-alive` headers :-\
Awscr::Signer::HeaderCollection::BLACKLIST_HEADERS << "connection"

module AWS
  abstract class Client
    macro service_name
      {{SERVICE_NAME}}
    end

    def initialize(
      @access_key_id = AWS.access_key_id,
      @secret_access_key = AWS.secret_access_key,
      @region = AWS.region,
      @endpoint = URI.parse("https://#{service_name}.#{region}.amazonaws.com"),
      @use_tls = AWS.use_tls
    )
      @signer = Awscr::Signer::Signers::V4.new(service_name, region, access_key_id, secret_access_key)
      @connection_pools = Hash({String, Int32?, Bool}, DB::Pool(HTTP::Client)).new
    end

    DEFAULT_HEADERS = HTTP::Headers{
      "Connection" => "keep-alive",
      "User-Agent" => "Crystal AWS #{VERSION}",
    }

    def get(path : String, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.get(path, headers: headers))
    end

    def get(path : String, headers = HTTP::Headers.new, &block : HTTP::Client::Response ->)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.get(path, headers: headers, &block))
    end

    def post(path : String, body : String, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.post(path, body: body, headers: headers))
    end

    def put(path : String, body : IO, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.put(path, body: body, headers: headers))
    end

    def head(path : String, headers : HTTP::Headers)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.head(path, headers))
    end

    def delete(path : String, headers = HTTP::Headers.new)
      headers = DEFAULT_HEADERS.dup.merge!(headers)
      http(&.delete(path, headers: headers))
    end

    protected getter endpoint

    protected def http(host = endpoint.host.not_nil!, port = endpoint.port, tls = @use_tls)
      pool = @connection_pools.fetch({host, port, tls}) do |key|
        @connection_pools[key] = DB::Pool.new(DB::Pool::Options.new(initial_pool_size: 0, max_idle_pool_size: 20)) do
          if port
            http = HTTP::Client.new(host, port, tls: tls)
          else
            http = HTTP::Client.new(host, tls: tls)
          end
          http.before_request do |request|
            # Apparently Connection: keep-alive causes trouble with signatures.
            # See https://github.com/taylorfinnell/awscr-signer/issues/56#issue-801172534
            request.headers.delete "Authorization"
            request.headers.delete "X-Amz-Content-Sha256"
            request.headers.delete "X-Amz-Date"
            @signer.sign request
          end

          http
        end
      end

      pool.checkout { |http| yield http }
    end
  end
end
