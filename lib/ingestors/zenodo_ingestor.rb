require 'rest-client'
require 'json'
require 'ostruct'
require 'cgi'

module Ingestors
  class ZenodoIngestor < Ingestor
    def self.config
      {
        key: 'zenodo',
        title: 'Zenodo API',
        category: :materials
      }
    end

    def read(url)
      # paged query
      next_page = url

      # Summary counters
      total_hits = 0
      total_pages = 0
      failed_pages = Set.new
      failed_attempts = 0
      total_records = 0
      processed_records = 0
      records_with_doi = 0
      records_without_doi = 0
      errors = []

      begin
        # process each page
        until next_page.nil?
          current_page = next_page

          Rails.logger.info("Fetching: #{current_page}")

          begin
            content = open_url(CGI.unescape_html(current_page))

            if content.nil?
              failed_pages << current_page
              Rails.logger.error("[ZENODO] No response received for: #{current_page}")
            end

            body = content.respond_to?(:read) ? content.read : content.to_s

            if body.empty?
              failed_pages << current_page
              failed_attempts += 1
              Rails.logger.error("[ZENODO] Empty response body for: #{current_page}")
            end

            results = JSON.parse(body)

            total_pages += 1

            # Total hits reported by Zenodo
            total_hits = results.dig('hits', 'total').to_i

            # Extract records
            hits = results.dig('hits', 'hits') || []

            total_records += hits.size

            hits.each do |item|
              if item['doi'].present?
                records_with_doi += 1
              else
                records_without_doi += 1
              end

              title = item.dig('metadata', 'title').to_s
              # Excluding Deliverables from the harvesting process
              if title.match?(/\AD\d+(?:\.\d+)+/)
                Rails.logger.info("[ZENODO] Skipping material: #{title}")
                next
              end

              processed_records += 1 if process_material(item)
            end

            # Get next page from Zenodo
            next_page = results.dig('links', 'next')

            # Avoid pagination loops
            if next_page == current_page
              Rails.logger.warn("[ZENODO] Repeated page URL: #{next_page}")
              next_page = nil
            end
          rescue StandardError => e
            failed_pages << current_page
            errors << "#{current_page}: #{e.message}"
          end
        end
      rescue Exception => e
        @messages << "#{self.class.name} failed with: #{e.message}"
      ensure
        missing_records = [total_hits - total_records, 0].max

        Rails.logger.info('')
        Rails.logger.info('----------------------------------------------------')
        Rails.logger.info('ZENODO SUMMARY REPORT')
        Rails.logger.info('----------------------------------------------------')
        Rails.logger.info("Total hits reported by Zenodo: #{total_hits}")
        Rails.logger.info("Total pages retrieved: #{total_pages}")
        Rails.logger.info("Failed pages (unique): #{failed_pages.size}")
        Rails.logger.info("Failed attempts: #{failed_attempts}")
        Rails.logger.info("Total records RETRIEVED: #{total_records}")
        Rails.logger.info("Total records PROCESSED: #{processed_records}")
        Rails.logger.info("Records with DOI: #{records_with_doi}")
        Rails.logger.info("Records without DOI: #{records_without_doi}")
        Rails.logger.info("Missing records: #{missing_records}")
        Rails.logger.info('----------------------------------------------------')
      end

      nil
    end

    private

    def process_material(input)
      # map top-level tags
      metadata = input['metadata']
      links = input['links']

      # copy values
      begin
        material = OpenStruct.new
        material.status = 'active'
        material.doi = input['doi'] unless metadata['doi'].nil?
        material.authors = []
        material.contributors = []
        unless metadata.nil?
          material.title = metadata['title'] unless metadata['title'].nil?
          material.description = process_description metadata['description']
          material.keywords = metadata['keywords'] unless metadata['keywords'].nil?
          material.licence = metadata['license']['id'] unless metadata.dig('license', 'id').nil?
          unless metadata['creators'].nil?
            metadata['creators'].each do |c|
              # Store the full name directly without trying to parse it
              material.authors << {
                name: c['name'].to_s.strip,
                orcid: c['orcid']
              }
            end
          end
          unless metadata['contributors'].nil?
            metadata['contributors'].each do |c|
              # Store the full name directly without trying to parse it
              material.contributors << {
                name: c['name'].to_s.strip,
                orcid: c['orcid']
              }
            end
          end

        end
        material.url = links['self_html'] if !links.nil? && !links['self_html'].nil?

        # add material to array
        add_material material
      rescue Exception => e
        @messages << "#{self.class.name} extract material fields failed with: #{e.message}"
      end

      # finished
      nil
    end

    def process_description(input)
      return nil if input.nil?

      input = CGI.unescape(input)
      convert_description(input)
    end
  end
end
