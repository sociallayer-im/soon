# A durable receipt for the exact immutable bytes checked before upload.
class ContentSafetyImage < ApplicationRecord
  validates :url, :sha256, presence: true
end
