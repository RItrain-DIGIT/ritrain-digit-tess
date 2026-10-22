require 'json'
require 'rest-client'
require 'erb'
require 'uri'
require 'ostruct'

module Ingestors
  class EvitaIngestor < Ingestor

    GITLAB_API_BASE = ENV.fetch('GITLAB_API_URL').strip.freeze
    GITLAB_API_BASE_URL = (GITLAB_API_BASE + '/api/v4').freeze
    GITLAB_PROJECT_PATH = ENV.fetch('GITLAB_PROJECT_PATH').strip.freeze
    GITLAB_PROJECT_URL = (GITLAB_API_BASE + GITLAB_PROJECT_PATH).freeze

    GITLAB_PAGES_URL = ENV.fetch(
      'GITLAB_PAGES_URL',
      GITLAB_PROJECT_URL
    ).strip.freeze

    unless GITLAB_API_BASE_URL.match?(%r{\Ahttps://})
      raise "Invalid GITLAB_API_BASE_URL: #{GITLAB_API_BASE_URL}"
    end

    def self.config
      {
        key: 'gitlab_ingestor',
        title: 'EVITA HPC',
        category: :any,
        description: 'Ingestor for the EVITA HPC training modules',
        parameters: {}
      }
    end

    def read(source_url)
      group_path = ERB::Util.url_encode(GITLAB_PROJECT_PATH)
      api_url = "#{GITLAB_API_BASE_URL}/groups/#{group_path}/projects"

      Rails.logger.info("GitLab group projects API URI: #{api_url}")

      response = RestClient.get(
         api_url,
         {
           accept: :json,
           params: { per_page: 100, include_subgroups: true },
           user_agent: 'TeSS GitLab Ingestor'
         }
      )

      projects = JSON.parse(response.body)

      unless projects.is_a?(Array)
        raise "Unexpected response for group #{GITLAB_PROJECT_PATH}"
      end

      if projects.empty?
        Rails.logger.warn("No accessible projects found in GitLab group: #{GITLAB_PROJECT_PATH}")
        return
      end

      projects.each do |project|
        Rails.logger.info("Harvesting the project: #{project['path_with_namespace']}")
        add_material(extract_material(project))
      end

      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("EVITA HTTP error: #{e.message}")
        raise

      rescue JSON::ParserError => e
        Rails.logger.error("EVITA returned invalid JSON: #{e.message}")
        raise

      rescue StandardError => e
        Rails.logger.error("EvitaIngestor failed: #{e.message}\n#{e.backtrace.join("\n")}")
        raise
    end

    def add_material(material)
      if material.is_a?(Hash)
        controller = MaterialsController.new
        controller.params = { material: material }
        material = OpenStruct.new(controller.send(:material_params))

        Rails.logger.info("Material: #{material}")
      end

      material = handle_auto_parsing(material)
      material = handle_controlled_vocabulary(material)

      @materials << material unless material.nil?
    end

    private

    def extract_material(project_data)
    {
      title: project_data['name'].presence || 'EVITA Training Module',
      description: project_data['description'].presence || 'EVITA HPC training modules',
      url: project_data['web_url'],
      purl: project_data['web_url'],
      provider: 'EVITA',
      licence: project_data.dig('license', 'name') || 'CC-BY-SA-4.0',
      keywords: %w[EuroHPC EVITA HPC GPU],
      target_audience: [
        'Researchers',
        'HPC Developers',
        'Software Engineers'
      ],
      status: :active,
      material_type: 'Hands-on tutorial'
    }
    end
  end
end

