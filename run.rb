require 'bundler/setup'
require 'net/http'
require 'nokogiri'
require 'pco_api'
require 'pry'
require 'time'
require 'uri'
require 'yaml'

class Labeler
  def initialize(config)
    @config = config
  end

  def api 
    @api ||= PCO::API.new(
      basic_auth_token: @config['personal_access_token']['app_id'],
      basic_auth_secret: @config['personal_access_token']['secret'],
    )
  end

  def run
    each_donation do |donation|
      next if donation.dig('attributes', 'payment_status') == 'failed'

      labels = donation.dig('relationships', 'labels', 'data')
      label_ids = labels.map { |l| l['id'] }
      date = donation.dig('attributes', 'created_at').split('T').first
      log_prefix = "donation #{donation['id']} on #{date}:"

      if (existing_label_ids = (giving_labels.keys & label_ids)).any?
        labels = existing_label_ids.map { |id| giving_labels.fetch(id)['attributes']['slug'] }
        puts "#{log_prefix} already has label #{labels.join(', ')}"
        next
      end

      person_id = donation.dig('relationships', 'person', 'data', 'id')
      unless person_id
        puts "#{log_prefix} no person linked to donation"
        next
      end
      person = api.people.v2.people[person_id].get
      campus_id = person.dig('data', 'relationships', 'primary_campus', 'data', 'id')
      unless campus_id
        puts "#{log_prefix} no campus for #{person['data']['attributes']['first_name']} #{person['data']['attributes']['last_name']}"
        next
      end
      campus = people_campuses.fetch(campus_id)
      label_slug = label_mappings[campus['attributes'].fetch('name')]
      puts "#{log_prefix} applying label #{label_slug} for #{person['data']['attributes']['first_name']} #{person['data']['attributes']['last_name']}..."
      label_id = giving_labels_by_slug[label_slug].fetch('id')
      add_label(donation, label_id)
    end
  end

  private

  # we are not allowed to edit the donation labels via the API for two reasons:
  # - the donation isn't in a batch (sometimes)
  # - the donation wasn't created via an external payment source
  # ...so we'll do it the hard way ;-)
  def add_label(donation, label_id)
    uri = URI("https://giving.planningcenteronline.com/donations/#{donation['id']}")
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri)
    request['Cookie'] = "planning_center_session=#{@config['login']['cookie']}"
    request['X-CSRF-Token'] = csrf_token
    encoded_params = URI.encode_www_form(
      '_method' => 'patch',
      'donation[id]' => donation['id'],
      'section' => 'labels',
      'donation[donations_labels_attributes][][id]' => '',
      'donation[donations_labels_attributes][][label_id]' => label_id,
    )
    request.body = encoded_params
    response = http.request(request)
    unless response.code == '200'
      p(csrf_token:, encoded_params:, response:, location: response['Location'])
      raise 'failed to add label'
    end
  end

  def csrf_token
    return @csrf_token if @csrf_token

    uri = URI('https://giving.planningcenteronline.com/dashboard')
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri)
    request['Cookie'] = "planning_center_session=#{@config['login']['cookie']}"
    response = http.request(request)
    if response['Location']
      puts response['Location']
      puts response.body
      exit 1
    end
    doc = Nokogiri::HTML(response.body)
    @csrf_token = doc.at_css('meta[name=csrf-token]')['content']
  end

  def label_mappings
    @label_mappings ||= @config['apply_labels_to_donations'].each_with_object({}) do |mapping, hash|
      hash[mapping.fetch('people_campus')] = mapping.fetch('giving_label')
    end
  end

  def each_donation
    offset = 0
    loop do
      payload = api.giving.v2.donations.get('offset' => offset, 'per_page' => 100, 'where[received_at][gt]' => after_date)
      payload['data'].each do |donation|
        yield donation
      end
      offset = payload.dig('meta', 'next', 'offset')
      break unless offset
    end
  end

  def after_date
    one_month = 60 * 60 * 24 * 30
    (Time.now - one_month).utc.strftime('%Y-%m-%dT00:00:00Z')
  end

  def giving_labels
    @giving_labels ||= api.giving.v2.labels.get(per_page: 100)['data'].each_with_object({}) do |label, hash|
      hash[label.fetch('id')] = label
    end
  end

  def giving_labels_by_slug
    @giving_labels_by_slug ||= giving_labels.each_with_object({}) do |(id, label), hash|
      hash[label.dig('attributes', 'slug')] = label
    end
  end

  def people_campuses
    @people_campuses ||= api.people.v2.campuses.get(per_page: 100)['data'].each_with_object({}) do |campus, hash|
      hash[campus.fetch('id')] = campus
    end
  end
end

config_path = File.expand_path('./config.yml', __dir__)
if !File.exist?(config_path)
  puts 'You must create a config.yml file'
  exit 1
end

puts "Applying Giving Labels run #{Time.now.strftime('%Y-%m-%d %I:%M %p')}"

config = YAML.load(File.read(config_path))
Labeler.new(config).run

puts 'done'
