class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_create :set_tsid_primary_key

  private

  def set_tsid_primary_key
    self.id ||= self.class.generate_tsid
  end

  def self.generate_tsid
    @tsid_generator ||= Tsid::Generator.new
    @tsid_generator.generate
  end
end
