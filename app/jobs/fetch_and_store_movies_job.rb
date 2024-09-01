class FetchAndStoreMoviesJob < ApplicationJob
  queue_as :default

  def perform(user)
    sections = fetch_sections(user)
    server_info = fetch_plex_server_info(user)

    sections.each do |section|
      connection = Faraday.new(url: "http://#{server_info[:ip]}:#{server_info[:port]}") do |faraday|
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
      end

      response = connection.get("/library/sections/#{section[:section_id]}/all") do |req|
        req.headers['Accept'] = 'application/xml'
        req.headers['X-Plex-Token'] = user.plex_token
        req.headers['X-Plex-Client-Identifier'] = user.plex_client_id
      end

      xml_doc = Nokogiri::XML(response.body)

      # Filter for movies only
      xml_doc.xpath('//Video[@type="movie"]').each do |video|
        unless user.movies.exists?(plex_id: video.attr('ratingKey'))
          user.movies.create(
            title: video.attr('title'),
            poster_url: "https://#{server_info[:ip]}:#{server_info[:port]}#{video.attr('thumb')}?X-Plex-Token=#{user.plex_token}",
            plex_id: video.attr('ratingKey'),
            genres: extract_genres(video),
            tagline: video.attr('tagline'),
            summary: video.attr('summary'),
            content_rating: video.attr('contentRating'),
            audience_rating: video.attr('audienceRating'),
            rating: video.attr('rating')
          )
        end
      end
    end
  end
  private

  def fetch_sections(user)
    server_info = fetch_plex_server_info(user)

    if server_info
      connection = Faraday.new(url: "http://#{server_info[:ip]}:#{server_info[:port]}") do |faraday|
        faraday.request :url_encoded
        faraday.adapter Faraday.default_adapter
      end

      response = connection.get('/library/sections') do |req|
        req.headers['Accept'] = 'application/xml'
        req.headers['X-Plex-Token'] = user.plex_token
        req.headers['X-Plex-Client-Identifier'] = user.plex_client_id
      end

      if response.status == 200
        xml_doc = Nokogiri::XML(response.body)
        sections = xml_doc.xpath('//Directory').map do |directory|
          {
            title: directory.attr('title'),
            section_id: directory.attr('key')
          }
        end
        sections
      else
        Rails.logger.error("Failed to fetch sections: #{response.body}")
        []
      end
    else
      Rails.logger.error("No Plex server info available")
      []
    end
  end

  def fetch_plex_server_info(user)
    connection = Faraday.new(url: 'https://plex.tv', request: { timeout: 10, open_timeout: 5 }) do |faraday|
      faraday.request :url_encoded
      faraday.adapter Faraday.default_adapter
    end
  
    response = connection.get('/api/v2/resources') do |req|
      req.headers['Accept'] = 'application/json'
      req.headers['X-Plex-Token'] = user.plex_token
      req.headers['X-Plex-Client-Identifier'] = user.plex_client_id
    end
  
    if response.status == 200
      servers = JSON.parse(response.body)
  
      # Find the first available server that provides 'server' capabilities
      server = servers.find { |s| s['provides'].include?('server') }
  
      if server
        connection_info = select_public_connection(server['connections'])
        if connection_info
          {
            ip: connection_info['address'],
            port: connection_info['port'],
            local: connection_info['local']
          }
        else
          Rails.logger.error("No suitable public connection found for Plex server")
          nil
        end
      else
        Rails.logger.error("No Plex servers found for user")
        nil
      end
    else
      Rails.logger.error("Failed to fetch Plex server info: #{response.body}")
      nil
    end
  end

  def select_public_connection(connections)
    # Prefer non-local (public) connections that are not relayed
    public_connection = connections.find { |conn| !conn['local'] && !conn['relay'] }
    return public_connection if public_connection
  
    # As a fallback, use a relayed connection (if available)
    connections.find { |conn| !conn['local'] && conn['relay'] }
  end

  def extract_genres(video)
    video.xpath('Genre').map { |genre| genre.attr('tag') }
  end
end