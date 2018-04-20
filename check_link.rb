require 'net/http'
require 'net/https'

def check_link(link)
  uri = URI(link)
  response = nil
  Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
    response = http.head(uri)
  end
  response.code
end

puts "checking 1..."
check_link "http://example.com"
puts "checked 1"
puts "checking 2..."
check_link "https://github.com/totocaster/metalsmith-tags/issues/53"
puts "checked 2"
