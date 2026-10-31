# frozen_string_literal: true
require_relative "storage/disk"
require_relative "data"
require_relative "web"

module Hamster
  module Storage
    class Attachments
      def self.migration_sql
        <<~SQL
          CREATE TABLE hamster_blobs (
            id TEXT PRIMARY KEY, storage_key TEXT NOT NULL UNIQUE, owner TEXT NOT NULL,
            filename TEXT NOT NULL, content_type TEXT NOT NULL, byte_size BIGINT,
            checksum TEXT, state TEXT NOT NULL CHECK (state IN ('pending','ready','deleting')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
          );
          CREATE TABLE hamster_attachments (
            id TEXT PRIMARY KEY, blob_id TEXT NOT NULL REFERENCES hamster_blobs(id),
            record_type TEXT NOT NULL, record_id TEXT NOT NULL, name TEXT NOT NULL,
            owner TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (blob_id, record_type, record_id, name)
          );
          CREATE INDEX hamster_attachments_blob ON hamster_attachments(blob_id);
          CREATE INDEX hamster_blobs_cleanup ON hamster_blobs(state, updated_at);
        SQL
      end
      def initialize(database:, adapter:)
        @database, @adapter = database, adapter
      end
      def with_connection
        @database.with_connection do |connection|
          raise Error, "Storage operations require their own idle DB connection" unless connection.idle?
          yield connection
        end
      end
      def upload(io, filename:, owner:, content_type: "application/octet-stream", max_bytes: 1048576)
        raise ArgumentError, "owner is required" if owner.to_s.empty?
        display = filename.to_s.tr("\\", "/").split("/").last.to_s.gsub(/[\x00-\x1f\x7f]/, "")
        raise ArgumentError, "filename must be valid UTF-8" unless display.valid_encoding?
        display = "download.bin" if display.empty?
        id, key = SecureRandom.hex(16), SecureRandom.hex(32)
        with_connection do |connection|
          connection.execute("INSERT INTO hamster_blobs(id,storage_key,owner,filename,content_type,state) VALUES($1,$2,$3,$4,$5,'pending')", [id, key, owner.to_s, display, content_type.to_s])
        end
        # Pending metadata commits before file creation. Failed writes or DB
        # outages remain discoverable and recoverable by explicit cleanup.
        metadata = @adapter.put(io, key: key, max_bytes: max_bytes)
        with_connection do |connection|
          connection.execute("UPDATE hamster_blobs SET byte_size=$1,checksum=$2,state='ready',updated_at=CURRENT_TIMESTAMP WHERE id=$3 AND state='pending'", [metadata.fetch("byte_size"), metadata.fetch("checksum"), id])
        end
        id
      end
      def authorize!(callback, metadata)
        raise Unauthorized, "Attachment access denied" unless callback && callback.call(metadata.dup.freeze)
      end
      def attach(blob_id:, record_type:, record_id:, name:, owner:, authorize:)
        with_connection do |connection|
          connection.transaction do
            blob = connection.execute("SELECT * FROM hamster_blobs WHERE id=$1 FOR UPDATE", [blob_id]).hashes.first
            raise MissingBlob, "Blob is not ready" unless blob && blob["state"] == "ready"
            raise Unauthorized, "Blob owner does not match" unless blob["owner"] == owner.to_s
            metadata = blob.merge("record_type" => record_type.to_s, "record_id" => record_id.to_s, "name" => name.to_s)
            authorize!(authorize, metadata)
            row = connection.execute("INSERT INTO hamster_attachments(id,blob_id,record_type,record_id,name,owner) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(blob_id,record_type,record_id,name) DO UPDATE SET name=EXCLUDED.name RETURNING id", [SecureRandom.hex(16), blob_id, record_type.to_s, record_id.to_s, name.to_s, owner.to_s]).hashes.first
            row.fetch("id")
          end
        end
      end
      def metadata(id)
        with_connection { |connection| connection.execute("SELECT * FROM hamster_blobs WHERE id=$1 AND state='ready'", [id]).hashes.first }
      end
      def open(id, authorize:)
        blob = metadata(id)
        raise MissingBlob, "Blob is not ready" unless blob
        authorize!(authorize, blob)
        io = @adapter.open(blob.fetch("storage_key"))
        begin
          digest, size = Digest::SHA256.new, 0
          while (chunk = io.read(65536))
            break if chunk.empty?
            size += chunk.bytesize
            digest.update(chunk)
          end
          unless size == blob.fetch("byte_size").to_i && digest.hexdigest == blob.fetch("checksum")
            raise IntegrityError, "Blob checksum or size mismatch"
          end
          io.rewind
          io
        rescue Exception
          io.close
          raise
        end
      end
      def download(id, authorize:)
        blob = metadata(id)
        raise MissingBlob, "Blob is not ready" unless blob
        io = open(id, authorize: authorize)
        begin
          headers = Downloads.headers(blob.fetch("filename"), "application/octet-stream", "attachment")
          [200, headers, FileBody.new(io)]
        rescue Exception
          io.close
          raise
        end
      end
      def detach(id, authorize:)
        with_connection do |connection|
          connection.transaction do
            row = connection.execute("SELECT * FROM hamster_attachments WHERE id=$1 FOR UPDATE", [id]).hashes.first
            next false unless row
            authorize!(authorize, row)
            connection.execute("DELETE FROM hamster_attachments WHERE id=$1", [id])
            true
          end
        end
      end
      def delete(id, authorize:)
        blob = with_connection do |connection|
          connection.transaction do
            row = connection.execute("SELECT * FROM hamster_blobs WHERE id=$1 FOR UPDATE", [id]).hashes.first
            next nil unless row
            authorize!(authorize, row)
            references = connection.execute("SELECT id FROM hamster_attachments WHERE blob_id=$1 LIMIT 1", [id]).rows
            raise InUse, "Blob still has attachment references" unless references.empty?
            connection.execute("UPDATE hamster_blobs SET state='deleting',updated_at=CURRENT_TIMESTAMP WHERE id=$1", [id])
            row
          end
        end
        return false unless blob
        @adapter.delete(blob.fetch("storage_key"))
        with_connection { |connection| connection.execute("DELETE FROM hamster_blobs WHERE id=$1 AND state='deleting'", [id]) }
        true
      end
      # Privileged maintenance; caller deliberately chooses a grace period.
      def cleanup(older_than:, limit: 100)
        raise ArgumentError, "cleanup limit must be positive" unless limit.is_a?(Integer) && limit > 0
        candidates = with_connection do |connection|
          connection.execute("SELECT b.id FROM hamster_blobs b WHERE b.updated_at < $1 AND NOT EXISTS (SELECT 1 FROM hamster_attachments a WHERE a.blob_id=b.id) ORDER BY b.updated_at,b.id LIMIT $2", [older_than, limit]).hashes
        end
        candidates.map do |row|
          begin
            delete(row.fetch("id"), authorize: ->(_metadata) { true })
            {"id" => row["id"], "deleted" => true}
          rescue InUse
            {"id" => row["id"], "deleted" => false}
          end
        end
      end
    end
  end
end
