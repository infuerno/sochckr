require 'json'
require 'redis'
require 'date'
require 'nokogiri'
require 'net/http'
require 'rest-client'
require 'moneta'
require 'api_cache'

API_BASE_URL = "https://api.stackexchange.com/2.2"
SITE_URL = "https://stackoverflow.com"
API_SITE_PARAMETER = "stackoverflow" # the official SE site parameter used in all API calls
DOMAINS_TO_IGNORE = ["1drv.ms", "codepen.io", "localhost", "imageshack.us", "websitetestlink.com", "pastebin.com", "gist.github.com"]

def refresh_sites(r)
  response = APICache.get("#{API_BASE_URL}/sites?page=1&pagesize=100&filter=default") #JSON.parse(open('./data/sites.json').read)
  json = JSON.parse(response)
  sites = json['items']

  puts "Found #{sites.length} sites"

  sites.each do |site|
    id = "site:#{site['api_site_parameter']}"
    url = "#{site['site_url']}"
    puts "Saving record for id: #{id}; url: #{url}"

    r.set(id, url)
  end
end

def get_filter(criteria, r)
  criteria = criteria.join(";")
  response = APICache.get("#{API_BASE_URL}/filters/create?unsafe=false&include=#{criteria}")
  json = JSON.parse(response) #JSON.parse(open('./data/filter.json').read)
  filter = json['items'][0]['filter']
end

def get_earliest_post_creation_date
  response = APICache.get("#{API_BASE_URL}/questions?site=stackoverflow&sort=creation&order=asc&page=1&pagesize=1")
  json = JSON.parse(response) #open('./data/posts_earliest.json').read)
  creation_date = json['items'][0]['creation_date']
end

def is_closed_question(question, r)
  if question['closed_date']
    puts "Question #{question['question_id']} is closed, reason is '#{question['closed_reason']}', skipping"
    r.sadd("questionschecked:#{API_SITE_PARAMETER}", question['question_id'])
    return true
  end
  return false
end

def is_answer_zero_score(answer, r)
  if answer['score'].to_i <= 0
    puts "Answer #{answer['answer_id']} has #{answer['score']} votes, skipping"
    r.sadd("answerschecked:#{API_SITE_PARAMETER}", answer['answer_id'])
    return true
  end
  return false
end

def get_links(html)
  # parse html for links and return
  doc = Nokogiri::HTML.parse(html)
  doc.css('a').map { |link| link['href'] }
end

def check_url(url, use_get = false, limit = 10)
  # You should choose a better exception.
  raise ArgumentError, 'Too many HTTP redirects' if limit == 0

  puts "Checking link: #{url} " + (use_get ? "using GET" : "using HEAD")
  if url.relative?
    url = URI("#{SITE_URL}#{url}")
  end
  response = nil
  begin
    Net::HTTP.start(url.host, url.port, :use_ssl => url.scheme == 'https') do |http|
      response = use_get ? http.get(url) : http.head(url)
    end
  rescue StandardError => e
    puts "ERROR: #{e}"
    puts "Returning status: #{e.class}"
    return e.class
  end

  return response.code if response.code == "200"
  return check_url(url, true) if !use_get # errant status code *may* be due to the use of "HEAD"; try "GET"
  return response.code if !response.header['location'] # not a redirect

  if response.header['location']
    puts "Redirect detected, following redirect url: #{response.header['location']}"
    redirect_url = URI.parse(response.header['location'])
    if redirect_url.relative? 
      puts "Redirect is relative"
      redirect_url = url + response.header['location']
    end
    check_url(redirect_url)
  end
end

def check_links(links, post_id, post_link, post_score, r)
  links.each do |link|
    url = URI(link)
    next if DOMAINS_TO_IGNORE.any? { |domain| url.host.end_with?(domain) }

    http_status = check_url(url)

    if http_status != "200"
      puts "Link is broken: status: #{http_status}, url: #{link}"
      # should really create a site set, but feels a bit of overkill
      #r.zadd("siteswithbrokenlinks", API_SITE_PARAMETER)

      brokenlink = Hash.new
      brokenlink['status'] = http_status
      brokenlink['text'] = "TODO"
      brokenlink['link'] = link
      brokenlink['position'] = 0

      brokenlinks = r.get("brokenlinks:#{API_SITE_PARAMETER}:#{post_id}")
      brokenlinks = brokenlinks ? JSON.parse(brokenlinks) : Array.new

      brokenlinks.push(brokenlink)
      r.set("brokenlinks:#{API_SITE_PARAMETER}:#{post_id}", brokenlinks.to_json)

      r.zadd("postswithbrokenlinks:#{API_SITE_PARAMETER}", post_score, post_id)
    end
  end
end

def get_questions(date, r)
  criteria = "question.body", "answer.body", "question.answers"
  filter = get_filter(criteria, r)

  puts "Getting post data from api.stackexchange.com"

  url = "#{API_BASE_URL}/questions?"
  url += "page=1&pagesize=100&order=asc&sort=activity"
  url += "&fromdate=#{date}"
  url += "&filter=#{filter}"
  url += "&site=#{API_SITE_PARAMETER}"

  response = APICache.get(url)
  #puts "Got data, response status: #{response.code}, parsing body"
  # TODO check all information in response
  json = JSON.parse(response)
  questions = json['items']
end

def check_issues(date, r)
  questions = get_questions(date, r)

  puts "Parsing #{questions.length} questions since date: #{date}"

  questions.each do |question|
    question_id = question['question_id']

    if r.sismember("questionschecked:#{API_SITE_PARAMETER}", question_id)
      puts "Question #{question_id} already checked, skipping"
      next
    end

    puts "Checking question: #{question_id}, #{question['link']}"

    next if is_closed_question(question, r)

    key = "posts:#{API_SITE_PARAMETER}:#{question_id}"
    r.hset(key, 'post_type', "question")
    r.hset(key, 'score', question['score'])
    r.hset(key, 'title', question['title'])
    r.hset(key, 'link', question['link'])
    r.hset(key, 'is_answered', question['is_answered'])
    r.hset(key, 'answer_count', question['answer_count'])    

    links = get_links(question['body'])
    links.uniq! # remove any repeated links, no point checking the same link twice

    puts links.length > 0 ? "Checking #{links.length} links in question body" : "No links in question body found"
    check_links(links, question_id, question['link'], question['score'], r)

    question['answers']&.each do |answer|
      answer_id = answer['answer_id']

      if r.sismember("answerschecked:#{API_SITE_PARAMETER}", answer_id)
        puts "Answer #{answer_id} already checked, skipping"
        next
      end

      puts "Checking answer: #{answer_id}"

      next if is_answer_zero_score(answer, r)

      key = "posts:#{API_SITE_PARAMETER}:#{answer_id}"
      r.hset(key, 'post_type', "answer")
      r.hset(key, 'score', answer['score'])
      r.hset(key, 'question_id', question_id)
      r.hset(key, 'is_accepted', answer['is_accepted'])

      links = get_links(answer['body'])

      puts links.length > 0 ? "Checking #{links.length} links in answer body" : "No links in answer body found"
      check_links(links, answer_id, answer['link'], answer['score'], r)

      r.sadd("answerschecked:#{API_SITE_PARAMETER}", answer_id)
    end

    r.sadd("questionschecked:#{API_SITE_PARAMETER}", question_id)
    r.save
  end
end

#check_url(URI("http://img710.imageshack.us/img710/9059/envelope.png"))
 
puts "Starting..."

APICache.store = Moneta.new(:Redis)
r = Redis.new(db: 1)
#r.flushall()
#refresh_sites(r)

date_from = get_earliest_post_creation_date
puts "Earliest post for site '#{API_SITE_PARAMETER}' was created at: #{Time.at(date_from)}"

date_from = (Time.now - (2 * 365 * 24 * 60 * 60)).to_i
date_to = Time.now.to_i
random_date = rand(date_from..date_to)
puts "Random date between then and now is: #{Time.at(random_date)}"
puts random_date
puts "Getting next 100 questions (and associated answers)"

#check_issues(random_date, r)

puts "Finished"

# r.zrevrangebyscore("postswithbrokenlinks:stackoverflow", "inf+", 0, :with_scores => true).each {|q, s| puts r.hgetall("questions:#{question}") }
posts = []
r.zrevrangebyscore("postswithbrokenlinks:stackoverflow", 100, 0, :with_scores => true).each {|q, s| posts.push(r.hgetall("posts:stackoverflow:#{q}")) }
# puts x.to_json # even this doesn't escape the /" properly
html = '<html>'
html += '<link rel="stylesheet" href="https://stackpath.bootstrapcdn.com/bootstrap/4.1.0/css/bootstrap.min.css" integrity="sha384-9gVQ4dYFwwWSjIDZnLEWnxCjeSWFphJiwGPXr1jddIhOegiu1FwO5qRGvFXOdJZ4" crossorigin="anonymous">'
html += '</html>'
html += '<body><div class="container-fluid"><div class="row"><div class="col"><table class="table-sm">'
html += '<thead><tr><th>Post</th><th>Score</th></tr></thead>'
html += '<tbody>'
posts.each { |post| html += "<tr><td><a href='#{post['link']}' target='_blank'>#{post['title']}</a></td><td>#{post['score']}</td></tr>"}
html += '</tbody></table></div></div></div></body></html>'

File.open('posts.html', 'w') { |file| file.write(html) }
system('open -a Safari posts.html')

# site:api_site_parameter
# create a redis STRING which has the key e.g. 'site:stackoverflow' and the value e.g. 'https://stackoverflow.com'

