# frozen_string_literal: true

require 'icalendar'
require 'nokogiri'
require 'tzinfo'
require 'open-uri'
require 'uri'

module Ingestors
  class IndicoIngestor < Ingestor
    include Ingestors::Concerns::SitemapHelpers

    def self.config
      {
        key: 'indico',
        title: 'Indico / .ics file',
        category: :events
      }
    end

    def read(source_url)
      @verbose = false

      sources = parse_sitemap(source_url)

      sources.each do |url|
        process_url(url)
      end
    end

    private

    def process_url(url)
      Rails.logger.info("[Indico] Processing source URL: #{url}")

      export_url = to_export(url)
      raise 'NOT an Indico link' if export_url.nil?

      content = fetch_calendar_content(export_url)

      Rails.logger.info("[Indico] Response size: #{content.bytesize} bytes")
      Rails.logger.debug("[Indico] response preview: #{content[0, 500].inspect}")

      # Parse the complete iCalendar document.
      calendars = Icalendar::Calendar.parse(content)
      events = Array(calendars).flat_map(&:events)

      Rails.logger.info("[Indico] Parsed *#{events.size}* events from #{export_url}!")

      if events.empty?
        Rails.logger.info("[Indico] No events found in calendar feed: #{export_url}")
        return
      end

      # Sorted chronologically: newest event first!
      sorted_events = events.sort_by do |calevent|
          calevent.dtstart&.to_time || Time.at(0).utc 
      end

      sorted_events.reverse!
      
      Rails.logger.info("[Indico] Processing events ... [IN PROGRESS]\n")

      sorted_events.each do |calevent|
        begin
          process_calevent(calevent)
        rescue StandardError => e
          Rails.logger.error(
            "Indico: failed to process event " \
            "#{calevent.uid}: #{e.class} - #{e.message}"
          )

          @messages << (
            "Failed to process Indico event " \
            "#{calevent.uid}: #{e.message}"
          )
        end
      end
    
    rescue StandardError => e
      Rails.logger.error("Indico ERROR for #{url}: #{e.class} - #{e.message}")

      messages << ("Process file URL [#{url}] failed with: #{e.message}")
    end

    def fetch_calendar_content(url)
      uri = URI.parse(url)

      # Preserve existing query parameters and ensure nc=yes is present.
      params = URI.decode_www_form(uri.query.to_s)
      params.reject! { |key, _value| key == 'nc' }
      params << ['nc', 'yes']
      uri.query = URI.encode_www_form(params)

      Rails.logger.info("[Indico] Opening calendar URI: #{uri}")

      options = {
        read_timeout: 30,
        open_timeout: 10,
        'User-Agent' => 'egi-automation',
        'Accept' => 'text/calendar'
      }

      URI.open(uri.to_s, options) do |response|
        status = response.status
        content_type = response.meta['content-type']

        Rails.logger.info(
          "[Indico] HTTP status: #{status.inspect}"
        )
        Rails.logger.info(
          "[Indico] HTTP Content-Type: #{content_type}"
        )

        response.read.force_encoding(Encoding::UTF_8)
      end
    end

    def to_export(url)
      uri = URI.parse(url)

      # Convert category page/feed URLs to Indico's HTTP API endpoint.
      match = uri.path.match(%r{/category/(\d+)(?:/events\.ics)?/?$})

      if match
         category_id = match[1]
         uri.path = "/export/categ/#{category_id}.ics"

         params = URI.decode_www_form(uri.query.to_s)
         params.reject! do |key, _value|
           %w[from to nc].include?(key)
         end
        params << ['from', '1900-01-01']
        params << ['to', '2100-12-31']
        params << ['nc', 'yes']

        uri.query = URI.encode_www_form(params)
        return uri.to_s
      end

      return url if uri.path.to_s.end_with?('.ics')
      return nil unless indico_page?(uri)

      ensure_events_ics_path(uri)
    end

    def indico_page?(uri)
      return false if uri.host.nil?

      uri.host.include?('indico')
    end

    def ensure_events_ics_path(uri)
      path = uri.path.to_s.chomp('/')

      unless path.end_with?('/events.ics')
        path = "#{path}/events.ics"
      end

      uri.path = path
      uri.to_s
    end

    def process_calevent(calevent)
      Rails.logger.info(
        "Event=#{calevent.uid.inspect}, " \
        "Title=#{calevent.summary.to_s.inspect}, " \
        "Start=#{calevent.dtstart.inspect}"
      )

      event = Event.new

      assign_basic_info(event, calevent)
      assign_time_info(event, calevent)
      assign_location_info(event, calevent)

      @events << event
    end

    def assign_basic_info(event, calevent)
      event.url = calevent.url.to_s
      event.title = calevent.summary.to_s
      event.description = calevent.description.to_s
      event.keywords = Array(calevent.categories).flatten
      event.contact = Array(calevent.contact).join(', ')
    end

    def assign_time_info(event, calevent)
      event.start = calevent.dtstart&.to_time
      event.end = calevent.dtend&.to_time
      event.timezone = get_tzid(calevent.dtstart)
    end

    def assign_location_info(event, calevent)
      location = calevent.location
      return if location.blank?

      description = calevent.description.to_s.downcase

      online = description.include?('zoom')

      hybrid = description.include?('hybrid') &&
               !description.include?('not hybrid') &&
               !description.include?('not a hybrid')

      event.venue = location.to_s
      event.online = online || hybrid

      event.presence =
        if hybrid
          :hybrid
        elsif online
          :online
        else
          :onsite
        end
    end

    def get_tzid(dtstart)
      return nil unless dtstart.respond_to?(:ical_params)

      tzid = dtstart.ical_params['tzid']
      return nil if tzid.nil?

      tzid.is_a?(Array) ? tzid.first.to_s : tzid.to_s
    end
  end
end
