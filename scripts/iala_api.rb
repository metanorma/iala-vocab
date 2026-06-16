require "httparty"
require "json"
require "digest"
require "fileutils"
require "uri"

module IalaApi
  API_BASE = "https://www.iala.int/wiki/dictionary/api.php".freeze
  RATE_LIMIT_DELAY = ENV.fetch("IALA_API_DELAY", "0.2").to_f

  # Returns array of {pageid, ns, title} hashes — all pages in category
  # Handles cmcontinue pagination automatically
  def self.get_category_members(category_name, limit: 500)
    members = []
    continue_token = nil
    
    loop do
      params = {
        action: "query", 
        format: "json",
        list: "categorymembers",
        cmtitle: "Category:#{category_name}",
        cmlimit: limit
      }
      params[:cmcontinue] = continue_token if continue_token
      
      result = api_request(params)
      members += result.dig("query", "categorymembers") || []
      
      continue_token = result.dig("continue", "cmcontinue")
      break unless continue_token
    end
    
    members
  end

  # Returns {text: rendered_html, categories: [...], langlinks: [...]}
  def self.parse_page(title)
    params = {
      action: "parse",
      format: "json",
      page: title,
      prop: "text|categories|langlinks"
    }
    
    result = api_request(params)
    parse_data = result["parse"] || {}
    
    {
      text: parse_data.dig("text", "*"),
      categories: parse_data["categories"] || [],
      langlinks: parse_data["langlinks"] || []
    }
  end

  # Returns raw wikitext string
  def self.get_page_content(title)
    params = {
      action: "query",
      format: "json",
      prop: "revisions",
      rvprop: "content",
      titles: title
    }
    
    result = api_request(params)
    pages = result.dig("query", "pages") || {}
    page = pages.values.first || {}
    revisions = page["revisions"] || []
    revision = revisions.first || {}
    
    revision["*"]
  end

  private

  def self.api_request(params)
    url_str = "#{API_BASE}?#{URI.encode_www_form(params)}"
    url_hash = Digest::MD5.hexdigest(url_str)
    cache_file = File.join(File.dirname(__FILE__), "..", "reference-docs", "api-cache", "#{url_hash}.json")
    
    if File.exist?(cache_file) && File.size(cache_file) > 0
      return JSON.parse(File.read(cache_file))
    end
    
    retries = 0
    max_retries = 3
    
    begin
      response = HTTParty.get(url_str)
      
      if response.code >= 500 && response.code < 600
        raise "Server error #{response.code}"
      elsif response.code >= 400 && response.code < 500
        raise RuntimeError, "Client error #{response.code}: #{response.body}"
      end
      
      sleep RATE_LIMIT_DELAY
      
      FileUtils.mkdir_p(File.dirname(cache_file))
      File.write(cache_file, response.body)
      
      JSON.parse(response.body)
    rescue => e
      if e.is_a?(RuntimeError) && e.message.start_with?("Client error")
        $stderr.puts "API Client Error: #{e.message}"
        raise
      end
      
      retries += 1
      if retries <= max_retries
        backoff = 2**(retries - 1)
        $stderr.puts "API Error: #{e.message}. Retrying in #{backoff}s (attempt #{retries}/#{max_retries})..."
        sleep backoff
        retry
      else
        $stderr.puts "API request failed after #{max_retries} retries: #{url_str}"
        raise
      end
    end
  end
end
