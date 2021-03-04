require 'bundler/setup'
require 'mechanize'
require 'pco_api'
require 'pry'
require 'time'
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
      labels = donation.dig('relationships', 'labels', 'data')
      label_ids = labels.map { |l| l['id'] }
      if (existing_label_ids = (giving_labels.keys & label_ids)).any?
        labels = existing_label_ids.map { |id| giving_labels.fetch(id)['attributes']['slug'] }
        puts "donation #{donation['id']}: already has label #{labels.join(', ')}"
      else
        person_id = donation.dig('relationships', 'person', 'data', 'id')
        person = api.people.v2.people[person_id].get
        campus_id = person.dig('data', 'relationships', 'primary_campus', 'data', 'id')
        unless campus_id
          puts "donation #{donation['id']}: no campus for #{person['data']['attributes']['first_name']} #{person['data']['attributes']['last_name']}"
          next
        end
        campus = people_campuses.fetch(campus_id)
        label_slug = label_mappings[campus['attributes'].fetch('name')]
        puts "donation #{donation['id']}: applying label #{label_slug} for #{person['data']['attributes']['first_name']} #{person['data']['attributes']['last_name']}..."
        label_id = giving_labels_by_slug[label_slug].fetch('id')
        add_label(donation, label_id)
      end
    end
  end

  private

  # we are not allowed to edit the donation labels via the API for two reasons:
  # - the donation isn't in a batch (sometimes)
  # - the donation wasn't created via an external payment source
  # ...so we'll do it the hard way ;-)
  def add_label(donation, label_id)
    agent.post(
      "https://giving.planningcenteronline.com/donations/#{donation['id']}",
        {
          '_method' => 'PATCH',
          'donation[id]' => donation['id'],
          'section' => 'labels',
          'donation[donations_labels_attributes][][label_id]' => label_id,
        },
        'X-CSRF-Token' => @csrf_token,
    )
  end

  def agent
    return @agent if @agent
    agent = Mechanize.new
    page = agent.get "https://login.planningcenteronline.com/login/new?ready=true"
    login_form = page.forms.first
    login_form.field_with(name: 'login').value = @config['login'].fetch('email')
    login_form.field_with(name: 'password').value = @config['login'].fetch('password')
    page = agent.submit(login_form)
    @csrf_token = page.at_css('meta[name="csrf-token"]').attributes['content'].value
    url = "/login?user_id=#{@config['login'].fetch('user_id')}"
    agent.post(
      url,
      '_method' => 'PUT',
      'authenticity_token' => @csrf_token,
    )
    @agent = agent
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
    one_week = 60 * 60 * 24 * 7
    (Time.now - one_week).utc.strftime('%Y-%m-%dT00:00:00Z')
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
