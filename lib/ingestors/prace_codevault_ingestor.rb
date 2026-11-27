# frozen_string_literal: true

require 'rest-client'
require 'json'
require 'ostruct'
require 'uri'
require 'logger'

module Ingestors
  class PraceCodevaultIngestor < Ingestor
    BASE_URL = 'https://repository.prace-ri.eu/git'
    API_URL = "#{BASE_URL}/api/v4".freeze
    GROUP_PATH = '36'

    def self.config
      {
        key: 'prace_codevault',
        title: 'PRACE CodeVault Repository',
        category: :materials
      }
    end

    def read(_url = nil)
      @harvested_projects = Set.new

      @prace_stats = {
        found: 0,
        processed: 0,
        skipped: 0,
        failed: 0
      }

      Rails.logger.info('Starting PRACE CodeVault ingestion')

      begin
        projects = fetch_group_projects

        @prace_stats[:found] = projects.size

        Rails.logger.info("Found #{projects.size} projects in GitLab group #{GROUP_PATH}")

        projects.each do |project|
          process_project(project)
        end
      rescue StandardError => e
        @messages << "#{self.class.name} failed with: #{e.message}"
        @prace_stats[:failed] += 1

        Rails.logger.error("Ingestion failed: #{e.class} - #{e.message}")
      ensure
        log_summary
      end

      nil
    end

    private

    def log_summary
      Rails.logger.info('========== PRACE CodeVault Summary Report ==========')
      Rails.logger.info("Group ID: #{GROUP_PATH}")
      Rails.logger.info("Projects found: #{@prace_stats[:found]}")
      Rails.logger.info("Projects processed: #{@prace_stats[:processed]}")
      Rails.logger.info("Projects skipped: #{@prace_stats[:skipped]}")
      Rails.logger.info("Projects failed: #{@prace_stats[:failed]}")
      Rails.logger.info("Unique projects harvested: #{@harvested_projects.size}")
      Rails.logger.info('====================================================')
    end

    # Retrieve all training projects from GitLab
    def fetch_group_projects
      endpoint = "#{API_URL}/groups/#{GROUP_PATH}/projects"

      fetch_paginated(endpoint, {
                        include_subgroups: true,
                        per_page: 100
                      })
    end

    # Generic GitLab pagination
    def fetch_paginated(endpoint, params = {})
      results = []
      page = 1

      loop do
        response = RestClient.get(
          endpoint,
          {
            accept: 'application/json',
            user_agent: 'PRACECodeVaultIngestor/1.0',
            params: params.merge(page: page)
          }
        )

        data = JSON.parse(response.body)

        break unless data.is_a?(Array)

        results.concat(data)

        next_page = response.headers[:x_next_page]
        break if next_page.nil? || next_page.to_s.empty?

        page = next_page.to_i
      end

      results
    end

    # Process an individual GitLab project
    def process_project(project)
      project_id = project['id']

      if project_id.nil?
        @prace_stats[:skipped] += 1
        Rails.logger.info('Skipping project without an ID')
        return
      end

      if @harvested_projects.include?(project_id)
        @prace_stats[:skipped] += 1
        Rails.logger.info("Skipping duplicate project ID=#{project_id}")
        return
      end

      @harvested_projects << project_id

      title = project['name']
      project_url = project['web_url']

      Rails.logger.info(
        '[PRACE CodeVault] ' \
        "ID=#{project_id}, " \
        "Title=#{title.inspect}, URL=#{project_url}"
      )

      if title.nil? || project_url.nil?
        @prace_stats[:skipped] += 1
        Rails.logger.info("Skipping project ID=#{project_id}: missing title or URL")
        return
      end

      begin
        # Retrieve README
        readme = fetch_readme(project_id, project['default_branch'])

        # Retrieve project file listing
        files = fetch_repository_tree(project_id)

        # Extract training metadata
        description = project['description'].to_s

        description = "#{description}\n\n#{readme}" if !readme.nil? && !readme.empty?

        # Create material
        material = OpenStruct.new

        material.status = 'active'
        material.title = title
        material.description = "Source: PRACE CodeVault\n\n#{description}"
        material.url = project_url

        material.authors = []
        material.contributors = []

        material.keywords = %w[
          PRACE
          CodeVault
          HPC
          Training
        ]

        material.description = "Source: PRACE CodeVault\n\n#{description}"

        # Store repository metadata in description
        unless files.empty?
          material.description += "\n\nRepository files:\n"

          files.each do |file|
            material.description += "- #{file['path']}\n"
          end
        end

        add_material material

        @prace_stats[:processed] += 1
      rescue StandardError => e
        @prace_stats[:failed] += 1

        @messages << "Project #{title} failed: #{e.message}"

        Rails.logger.error(
          "Project ID=#{project_id}, Title=#{title.inspect} failed: " \
          "#{e.class} - #{e.message}"
        )
      end
    end

    # Retrieve README from GitLab
    def fetch_readme(project_id, branch)
      return nil if branch.nil?

      readme_names = [
        'README.md',
        'README',
        'readme.md',
        'Readme.md'
      ]

      readme_names.each do |filename|
        path = URI.encode_www_form_component(filename)

        endpoint =
          "#{API_URL}/projects/#{project_id}/repository/files/#{path}/raw"

        begin
          response = RestClient.get(
            endpoint,
            {
              accept: 'text/plain',
              params: { ref: branch }
            }
          )

          return response.body
        rescue RestClient::ExceptionWithResponse
          next
        end
      end

      nil
    end

    # Retrieve all files in a repository
    def fetch_repository_tree(project_id)
      endpoint =
        "#{API_URL}/projects/#{project_id}/repository/tree"

      fetch_paginated(endpoint, {
                        recursive: true,
                        per_page: 100
                      })
    rescue RestClient::ExceptionWithResponse => e
      @messages << "Cannot retrieve tree for project #{project_id}: #{e.http_code}"
      Rails.logger.error("Cannot retrieve repository tree for project #{project_id}: HTTP #{e.http_code}")
      []
    end
  end
end
