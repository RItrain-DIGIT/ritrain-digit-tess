#!/bin/bash
docker compose run app bundle install
docker compose run app bundle exec rake db:setup
docker compose run app yarn install