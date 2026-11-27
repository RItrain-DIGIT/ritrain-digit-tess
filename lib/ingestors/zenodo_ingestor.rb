require 'rest-client'
require 'json'
require 'ostruct'
require 'cgi'

module Ingestors
  class ZenodoIngestor < Ingestor
    MAX_RETRIES = 5
    MAX_RETRY_WAIT = 120
    PAGE_DELAY = 5

    RETRYABLE_HTTP_CODES = [429, 500, 502, 503, 504].freeze

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

          Rails.logger.info("[ZENODO] Fetching: #{current_page}")

          begin
            body, attempts = fetch_zenodo_page(current_page)

            failed_attempts += attempts

            # Delay between successful page requests
            sleep(PAGE_DELAY)

            raise 'Empty response body' if body.nil? || body.empty?

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
            Rails.logger.error("[ZENODO] Failed page: #{current_page}")
            Rails.logger.error("[ZENODO] #{e.class}: #{e.message}")

            # Stop pagination rather than retrying the same
            # page indefinitely outside the retry mechanism.
            next_page = nil
            break
          end
        end
      rescue Exception => e
        @messages << "#{self.class.name} failed with: #{e.message}"
        Rails.logger.error("[ZENODO] Ingestor failed: #{e.class} - #{e.message}")
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

        unless failed_pages.empty?
          Rails.logger.warn('[ZENODO] Failed page URLs:')

          failed_pages.each do |page|
            Rails.logger.warn("[ZENODO] #{page}")
          end
        end

        unless errors.empty?
          Rails.logger.warn('[ZENODO] Errors:')

          errors.each do |error|
            Rails.logger.warn("[ZENODO] #{error}")
          end
        end
      end

      nil
    end

    private

    # Fetch Zenodo API page with retry and exponential backoff.
    def fetch_zenodo_page(url, max_retries: MAX_RETRIES)
      retries = 0

      begin
        content = open_url(CGI.unescape_html(url))
        raise 'No response received from Zenodo' if content.nil?

        body = content.respond_to?(:read) ? content.read : content.to_s
        raise 'Empty response body from Zenodo' if body.empty?

        [body, retries]
      rescue RestClient::Exception => e
        status = e.response&.code.to_i
        retryable = RETRYABLE_HTTP_CODES.include?(status) ||
                    e.response.nil?

        raise unless retryable

        retries += 1

        if retries > max_retries
          Rails.logger.error("[ZENODO] Maximum retries exceeded for #{url}: #{e.message}")
          raise
        end

        retry_after = e.response&.headers&.[](:retry_after)

        wait_time =
          if retry_after
            retry_after.to_f
          else
            2**retries
          end

        wait_time = [[wait_time, MAX_RETRY_WAIT].min, 1].max

        Rails.logger.warn(
          "[ZENODO] HTTP #{status} - retry #{retries}/#{max_retries} " \
          "in #{wait_time} seconds"
        )

        sleep(wait_time)
        retry
      rescue StandardError => e
        retries += 1
        if retries > max_retries

          Rails.logger.error(
            "[ZENODO] Request failed after #{max_retries} retries: " \
            "#{e.class} - #{e.message}"
          )
          raise
        end

        wait_time = [2**retries, MAX_RETRY_WAIT].min

        Rails.logger.warn(
          "[ZENODO] Request error: #{e.class} - #{e.message}. " \
          "Retry #{retries}/#{max_retries} in #{wait_time} seconds"
        )

        sleep(wait_time)
        retry
      end
    end

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
        Rails.logger.info("[ZENODO] #{material.title}")

        # add material to array
        add_material material
        true
      rescue Exception => e
        message = "#{self.class.name} extract material fields failed with: #{e.message}"
        @messages << message
        Rails.logger.error("[ZENODO] #{message}")
        false
      end
    end

    def process_description(input)
      return nil if input.nil?

      input = CGI.unescape(input)
      convert_description(input)
    end
  end
end
