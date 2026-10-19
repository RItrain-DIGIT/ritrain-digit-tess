# lib/ingestors/gitlab_ingestor.rb

require 'json'
require 'rest-client'
require 'erb'
require 'uri'
require 'ostruct'

module Ingestors
  class GitlabIngestor < Ingestor

    GITLAB_PROJECT_PATH = ENV.fetch('GITLAB_PROJECT_PATH').strip.freeze    
    GITLAB_API_BASE = ENV.fetch('GITLAB_API_BASE').strip.sub(%r{/+\z}, '').freeze
    GITLAB_PAGES_URL = ENV.fetch('GITLAB_PAGES_URL').strip.freeze

    unless GITLAB_API_BASE.match?(%r{\Ahttps://})
      raise "Invalid GITLAB_API_BASE: #{GITLAB_API_BASE}"
    end

    def self.config
      {
        key: 'gitlab_ingestor',
        title: 'EuroHPC JU',
        category: :any,
        description: 'Ingestor for EuroHPC JU training modules',
        parameters: {}
      }
    end

    def read(source_url)
      group_path = ERB::Util.url_encode(GITLAB_PROJECT_PATH)
      api_url = "#{GITLAB_API_BASE}/groups/#{group_path}/projects"
      Rails.logger.info("GitLab API URI: #{api_url}")

      response = RestClient.get(api_url)
      projects = JSON.parse(response.body)

      raise "No *accessible* projects found in GitLab group: #{GITLAB_PROJECT_PATH}" if projects.empty?

      projects.each do |project|
        add_material(extract_material(project))
      end
      rescue RestClient::ExceptionWithResponse => e
        Rails.logger.error("GitlabIngestor HTTP error: #{e.message}")
      raise
      rescue StandardError => e
        Rails.logger.error("GitlabIngestor failed: #{e.message}\n#{e.backtrace.join("\n")}")
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
        title: project_data['name'].presence || 'USTUTT Pilot Training Modules',
        description: project_data['description'].presence || 'USTUTT Pilot Training modules.',
        url: GITLAB_PAGES_URL,
        purl: project_data['web_url'],
        provider: 'EuroHPC JU / University of Stuttgart',
        licence: 'CC-BY-SA-4.0',
        keywords: %w[CUDA GPU HPC Parallel-Computing C++],
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

