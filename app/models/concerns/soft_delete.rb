# Soft delete: `destroy` stamps `deleted_at` instead of removing the row, and a
# `default_scope` hides stamped rows from every query that doesn't ask for them.
#
# Adapted from homeland's concern of the same name with one deliberate rename.
# There, the original hard `destroy` was aliased to `destroy!` — which reads in
# Rails as "destroy, raising on failure" and actually means "really delete".
# Here it is `hard_destroy!`, so nothing deletes a row by accident while
# reaching for the bang method it expects.
#
# `default_scope` is not free (`unscoped` drops ordering too, and its
# interaction with joins is subtle), but it is the only way that does not
# depend on every future query remembering `.where(deleted_at: nil)`.
module SoftDelete
  extend ActiveSupport::Concern

  included do
    default_scope { where(deleted_at: nil) }

    scope :with_deleted, -> { unscope(where: :deleted_at) }
    scope :only_deleted, -> { with_deleted.where.not(deleted_at: nil) }
  end

  # `deleted_by` is the person who pressed delete — the author or a manager.
  # Stored as an id rather than homeland's `who_deleted` login string, because
  # handles can be renamed and a copied string goes stale.
  def soft_delete!(by: nil)
    return true if deleted?

    now = Time.current
    update_columns(deleted_at: now, deleted_by_id: by&.id, updated_at: now)
    true
  end

  def restore!
    return true unless deleted?

    update_columns(deleted_at: nil, deleted_by_id: nil, updated_at: Time.current)
    true
  end

  def destroy
    run_callbacks(:destroy) do
      soft_delete! if persisted?
      @destroyed = true
    end
    freeze
  end

  def hard_destroy!
    self.class.delete(id)
  end

  def deleted? = deleted_at.present?
end
