class AddAccountToFamilyDocuments < ActiveRecord::Migration[8.1]
  # The document store had no account dimension: every search was family-wide by
  # construction, which was tolerable while only /imports fed it and stopped
  # being so once every Statement Vault upload was indexed. The link already
  # existed in `metadata`, but a jsonb key cannot be joined, indexed usefully or
  # enforced, so it becomes a real column.
  #
  # Nullable on purpose: a document with no account (a tax return, a contract)
  # is a legitimate row, and only a document that names an account it is not
  # yours to see gets filtered out.
  def up
    add_reference :family_documents, :account, type: :uuid, null: true, foreign_key: true, index: true

    # Backfill from the metadata key written since the vault bridge landed.
    execute <<~SQL
      UPDATE family_documents
      SET account_id = (metadata->>'account_id')::uuid
      WHERE metadata->>'account_id' IS NOT NULL
        AND (metadata->>'account_id') ~ '^[0-9a-fA-F-]{36}$'
        AND EXISTS (SELECT 1 FROM accounts WHERE accounts.id = (family_documents.metadata->>'account_id')::uuid)
    SQL
  end

  def down
    remove_reference :family_documents, :account, foreign_key: true
  end
end
