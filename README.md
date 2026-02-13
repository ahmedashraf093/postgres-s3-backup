# PostgreSQL S3 Backup & Restore (Granular)

This project provides Docker images to automatically back up **all** PostgreSQL databases in a cluster to AWS S3, and to restore specific or all databases as needed.

## Key Features

- **Granular Backups:** Iterates through every database in the cluster and creates separate `.dump` files (Custom format).
- **Globals Support:** Automatically backs up PostgreSQL globals (roles, groups, permissions).
- **S3 Directory Structure:** Organizes backups into timestamped directories (`S3_PREFIX/YYYY-MM-DD-HH-mm-ss/`).
- **Docker Secrets Support:** Natively supports reading passwords and AWS keys from files using `_FILE` environment variables (ideal for Docker Swarm/Kubernetes).
- **Flexible Restoration:** Restore a single database or the entire cluster from a specific timestamp.
- **Automated Cleanup:** Prunes old backups based on a retention period.

---

## Usage

### Backup Configuration

```yaml
services:
  postgres-backup:
    image: 057442118690.dkr.ecr.me-south-1.amazonaws.com/postgres-backup-s3:latest
    environment:
      SCHEDULE: '@every 6h'
      BACKUP_KEEP_DAYS: 7
      S3_REGION: me-south-1
      S3_BUCKET: my-muthmer-backups
      S3_PREFIX: backups
      POSTGRES_HOST: postgres
      POSTGRES_USER: postgres
      # Securely load from Docker Swarm secrets
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
      S3_ACCESS_KEY_ID_FILE: /run/secrets/aws_access_key_id
      S3_SECRET_ACCESS_KEY_FILE: /run/secrets/aws_secret_access_key
    secrets:
      - postgres_password
      - aws_access_key_id
      - aws_secret_access_key
    networks:
      - data-internal
      - traefik-public # Required for S3 internet access
```

### Environment Variables

| Variable | Description | Required |
| :--- | :--- | :--- |
| `S3_BUCKET` | Name of the S3 bucket. | Yes |
| `S3_REGION` | AWS Region (e.g., `me-south-1`). | Yes |
| `POSTGRES_HOST` | Hostname of the Postgres instance. | Yes |
| `POSTGRES_USER` | Admin user (must have permission to list all DBs). | Yes |
| `POSTGRES_PASSWORD` | Password for the Postgres user. | Optional* |
| `POSTGRES_PASSWORD_FILE`| Path to file containing the password. | Optional* |
| `S3_ACCESS_KEY_ID` | AWS Access Key ID. | Optional* |
| `S3_ACCESS_KEY_ID_FILE` | Path to file containing Access Key. | Optional* |
| `S3_SECRET_ACCESS_KEY` | AWS Secret Access Key. | Optional* |
| `S3_SECRET_ACCESS_KEY_FILE`| Path to file containing Secret Key. | Optional* |
| `SCHEDULE` | Cron schedule (e.g., `@every 6h`). Omit to run once. | No |
| `S3_PREFIX` | S3 folder prefix (defaults to `backups`). | No |
| `BACKUP_KEEP_DAYS` | How many days to keep backups in S3. | No |
| `PASSPHRASE` | GPG passphrase for encrypted backups. | No |

*\* Note: You must provide either the direct value or the `_FILE` path for credentials.*

---

## Restore Procedures

### 1. List Available Backups
Run the restore script without arguments to see available timestamps:
```sh
docker exec <container_id> sh /restore.sh
```

### 2. Restore a Specific Database
To restore a specific database (e.g., `auth_service`) from a timestamp:
```sh
docker exec <container_id> sh /restore.sh <TIMESTAMP> <DB_NAME>
```

### 3. Full Cluster Recovery
To restore **all** databases found in a backup folder:
```sh
docker exec <container_id> sh /restore.sh <TIMESTAMP> all
```

> [!CAUTION]
> **DATA LOSS!** The restore script will drop existing databases before recreating them from the backup. Active connections will be automatically terminated.

---

## Development & Build

To build the image for a specific PostgreSQL version (e.g., 16):

```sh
docker build --build-arg POSTGRES_VERSION=16 -t your-registry/postgres-backup-s3:latest .
```

## Acknowledgements

This project is a heavily modified version of the [Solectrus](https://github.com/solectrus/postgres-s3-backup) and [Eeshugerman](https://github.com/eeshugerman/postgres-backup-s3) forks, updated for granular multi-database support and Docker Swarm compatibility.
