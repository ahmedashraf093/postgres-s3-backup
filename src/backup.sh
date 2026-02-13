#! /bin/sh

set -e
set -o pipefail

source ./env.sh

# Use dashes for timestamp to be S3/path friendly
timestamp=$(date +"%Y-%m-%dT%H-%M-%S")
backup_parent_dir="/tmp/backups"
backup_dir="${backup_parent_dir}/${timestamp}"

mkdir -p "$backup_dir"

echo "Fetching database list from $POSTGRES_HOST..."
# List databases, excluding templates
# -t: tuples only, -A: unaligned
dbs=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d postgres -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

if [ -z "$dbs" ]; then
    echo "No databases found!"
    exit 1
fi

echo "Found databases: $(echo $dbs | tr '\n' ' ')"

for db in $dbs; do
  echo "Backing up database: $db..."
  # Use Custom format (-Fc) which is compressed by default and allows selective restore
  pg_dump -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$db" -Fc -f "$backup_dir/${db}.dump"
done

echo "Backing up globals (roles, groups)..."
# Globals must be SQL format
pg_dumpall -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" --globals-only --clean --if-exists | gzip > "$backup_dir/globals.sql.gz"

if [ -n "${PASSPHRASE:-}" ]; then
  echo "Encrypting backups..."
  for file in "$backup_dir"/*;
  do
    gpg --symmetric --batch --passphrase "$PASSPHRASE" "$file"
    rm "$file"
    mv "${file}.gpg" "${file}.gpg" 2>/dev/null || true # rename if gpg adds extension, though --output can control it. 
    # Default gpg behavior adds .gpg.
    # The previous loop might fail if I rm the file before checking.
    # Correct way:
    # gpg -c file -> file.gpg
    # rm file
  done
fi

echo "Uploading backups to s3://${S3_BUCKET}/${S3_PREFIX}/${timestamp}/..."
aws $aws_args s3 cp "$backup_dir" "s3://${S3_BUCKET}/${S3_PREFIX}/${timestamp}/" --recursive

echo "Cleaning up local files..."
rm -rf "$backup_parent_dir"

echo "Backup complete."

# Retention logic
if [ -n "${BACKUP_KEEP_DAYS:-}" ]; then
  sec=$((86400*BACKUP_KEEP_DAYS))
  date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
  backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

  echo "Removing old backups from $S3_BUCKET older than $date_from_remove..."
  # This deletes objects. Empty prefixes (directories) might remain in some S3 views but don't cost money.
  aws $aws_args s3api list-objects \
    --bucket "${S3_BUCKET}" \
    --prefix "${S3_PREFIX}" \
    --query "${backups_query}" \
    --output text \
    | xargs -r -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"'KEY'
  echo "Removal complete."
fi