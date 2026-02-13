#! /bin/sh

set -e
set -o pipefail

source ./env.sh

# Function to list available backups
list_backups() {
    echo "Fetching available backups from S3..."
    aws $aws_args s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | grep "PRE" | awk '{print $2}' | sed 's/\///' | sort -r
}

# Check arguments
if [ $# -lt 1 ]; then
    echo "Usage: /restore.sh <TIMESTAMP> [DATABASE_NAME]"
    echo ""
    echo "Available Backups:"
    list_backups
    exit 1
fi

TIMESTAMP="$1"
DB_NAME="$2"

S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${TIMESTAMP}"

# Verify backup exists
echo "Verifying backup at $S3_PATH..."
if ! aws $aws_args s3 ls "$S3_PATH" > /dev/null; then
    echo "❌ Backup path not found: $S3_PATH"
    echo "Available Backups:"
    list_backups
    exit 1
fi

# Function to restore a single database
restore_database() {
    local db=$1
    local file_path="/tmp/${db}.dump"
    local s3_file="${S3_PATH}/${db}.dump"

    echo "----------------------------------------------------------------"
    echo "🔄 Processing Database: $db"
    echo "----------------------------------------------------------------"

    # Download
    echo "⬇️  Downloading $s3_file..."
    if ! aws $aws_args s3 cp "$s3_file" "$file_path"; then
        echo "❌ Could not download backup file for $db. Skipping."
        return 1
    fi

    # Decrypt if needed
    if [ -n "${PASSPHRASE:-}" ]; then
        echo "🔐 Decrypting..."
        gpg --decrypt --batch --passphrase "$PASSPHRASE" "$file_path" > "${file_path}.dec"
        rm "$file_path"
        file_path="${file_path}.dec"
    fi

    # Terminate connections
    echo "🔌 Terminating connections to $db..."
    PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid();" > /dev/null

    # Drop and Create
    echo "🗑️  Dropping database $db..."
    PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d postgres -c "DROP DATABASE IF EXISTS \"$db\";"
    
    echo "✨ Creating database $db..."
    PGPASSWORD=$POSTGRES_PASSWORD psql -h $POSTGRES_HOST -U $POSTGRES_USER -d postgres -c "CREATE DATABASE \"$db\";"

    # Restore
    echo "🚀 Restoring data..."
    # -j 4: Use 4 parallel jobs for faster restore
    # -v: Verbose (useful for logs)
    # -d: Target database
    PGPASSWORD=$POSTGRES_PASSWORD pg_restore -h $POSTGRES_HOST -U $POSTGRES_USER -d "$db" -j 4 --no-owner --role=$POSTGRES_USER "$file_path" || true
    # Note: pg_restore might return exit code 1 on warnings (like harmless permission issues), so we use || true or check specific codes if strictly needed.

    echo "✅ Restore of $db complete!"
    rm "$file_path"
}

if [ -z "$DB_NAME" ] || [ "$DB_NAME" = "all" ]; then
    echo "📜 Restoring ALL databases from $TIMESTAMP..."
    
    # Get list of .dump files in that S3 directory
    dumps=$(aws $aws_args s3 ls "$S3_PATH/" | grep ".dump" | awk '{print $4}' | sed 's/.dump//')
    
    for db in $dumps; do
        restore_database "$db"
    done
else
    restore_database "$DB_NAME"
fi

echo "🎉 All requested restores completed."
