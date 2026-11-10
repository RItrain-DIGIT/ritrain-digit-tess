# RItrain-DIGIT TeSS Setup

This guide describes the RItrain-DIGIT-specific setup and operational tasks for this TeSS fork. For general Docker guidance, see the [Docker guide](docker.md).

## Architecture

The application and its supporting services run with Docker Compose. In development, the Rails application is available directly on the host at `http://localhost:3000`; no Nginx container, custom hostname, or TLS certificate is needed. In production, a separate Nginx container terminates HTTPS and forwards requests to Puma through a Unix socket in a Docker volume shared by Nginx and the application.

In **development**, the repository is mounted into the application container. Code changes are available immediately, and uploaded files are stored in the repository's `public/system` directory (which is ignored by Git).

In **production**, the application runs from a Docker image that must be rebuilt when application code changes. Uploaded files are stored separately in the persistent Docker volume named `uploads`.

The production Compose configuration publishes HTTPS on port `443`. Its Nginx configuration and certificates must be in place before starting the production stack.

## Prerequisites

- Git, Docker Engine, and the Docker Compose plugin.
- For production: a DNS name pointing to the host, with port `443` available, and a valid Let's Encrypt certificate with its configuration files.

The default production hostname in this repository is `registry.hopto.org`. Replace it with the hostname for your deployment wherever it appears in the following configuration steps. Development uses `localhost:3000` and does not require a hostname or certificate.

## Configuration

### Hostname and TLS

1. For production, set `TESS_BASE_HOST` in `.env` to the hostname that points to the deployment host.

2. Update the Nginx server block in `nginx/sites-enabled/tess`: set `server_name` and the certificate paths to match your hostname. The `letsencrypt` directory in the repository root is mounted into the Nginx container at `/etc/letsencrypt`; its structure should match the usual `/etc/letsencrypt` directory, including the certificate files referenced by the Nginx configuration.

3. Create the environment and application configuration files:

```sh
cp env.sample .env
cp config/tess.example.yml config/tess.yml
cp config/secrets.example.yml config/secrets.yml
cp config/ingestion.example.yml config/ingestion.example.yml
```

Edit `.env` and replace placeholder credentials with deployment-specific values; it holds only Docker and infrastructure settings (`PREFIX`, `TESS_BASE_HOST`, database, admin user). Application settings live in the other two files:

- `tess.yml` controls TeSS features and branding, the EGI LLM endpoint and model (`egi_llm`), and the settings of the custom ingestors (`ingestors`).
- `secrets.yml` holds application secrets and external service credentials, including the EGI Check-in credentials (`egi`) and the EGI LLM API key (`egi_llm_api_key`). The EGI login button is shown only when `egi.client_id` is set.

## Running the application

### Development

The development Compose configuration mounts the working tree into the application container. Following the further steps from [Docker guide: Configuration](docker.md#configuration), set up dependencies and the database, then start the services:

```sh
docker compose run app bundle install
docker compose run app bundle exec rake db:setup
docker compose run app yarn install
docker compose up -d
```

Open `http://localhost:3000` in a browser. The development stack also includes Adminer, available at `http://localhost:8080` from the Docker host. Development does not start Nginx or require HTTPS.

### Production

Build and start the production services:

```sh
docker compose -f docker-compose-prod.yml up -d --build
```

On the first deployment, initialize the database:

```sh
docker compose -f docker-compose-prod.yml exec app bundle exec rake db:setup DISABLE_DATABASE_ENVIRONMENT_CHECK=1
```

For later releases, rebuild and start the updated services, then apply database migrations:

```sh
docker compose -f docker-compose-prod.yml up -d --build
docker compose -f docker-compose-prod.yml exec app bundle exec rake db:migrate
```

Uploaded files are kept in the `uploads` volume when application containers are replaced. Back up this volume separately as described below.

Nginx and Puma share the `puma-socket` volume for app traffic; no application TCP port is published in production.

### Import training materials

To fetch the training materials, run:

```sh
docker exec -it ritrain-app bundle exec rake tess:automated_ingestion
```

## Backups and restores

The Git-ignored `backup` directory is intended for database dumps and uploaded-file archives. Keep copies of backups outside the host as well; data stored only on the deployment host is not protected against host failure.

### Back up the database

The `backup_database.sh` script handles both database backups and restores. It detects the environment from a running app container; alternatively, pass `production` or `development` explicitly. If no running app container is found, it defaults to `production`, so specify the environment when operating on a stopped stack. The database backup is created in custom PostgreSQL dump format (`.dump`).

```sh
./scripts/backup_database.sh backup backup/2026-10-20/tess_20261020_081849.dump
```

If the dump path is omitted, the script creates a timestamped file under `backup/`. For development, pass `development` instead of `production`.

### Back up uploaded files

The `backup_uploads.sh` script backs up the application's `public/system` directory. It uses the same environment detection and optional environment argument as the database script, including the `production` default when no app container is running.

```sh
./scripts/backup_uploads.sh backup backup/2026-10-20/uploads.tar.gz
```

If the archive path is omitted, the script creates a timestamped archive under `backup/`.

### Restore

> **Warning:** Restoring a database replaces the entire configured database. Restoring uploaded files deletes the current contents of `public/system` before extracting the archive. Verify the target environment and take a fresh backup before proceeding.

Restore a database dump with `backup_database.sh`:

```sh
./scripts/backup_database.sh restore backup/2026-10-20/tess_20261020_081849.dump production
```

Beside restoring database, the script stops and starts services automatically, does reindexing, etc. The target Compose services must be available, and `.env` must be configured in the repository root.

Restore uploaded files from an archive with:

```sh
./scripts/backup_uploads.sh restore backup/2026-10-20/uploads.tar.gz
```

Use the same environment for both the database and uploads operations to restore a consistent backup set.