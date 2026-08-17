class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def index? = false
  def show? = false
  def create? = false
  def new? = create?
  def update? = false
  def edit? = update?
  def destroy? = false

  private

  def owner?(record)
    record.respond_to?(:owner_id) && record.owner_id == user&.id
  end

  # !! because `user&.…` yields nil for an anonymous caller, and these feed
  # blueprint fields (can_edit, can_manage) whose clients are typed boolean —
  # a null there is not the same value as false.
  def group_admin?(group)
    !!user&.memberships&.exists?(group: group, role: %w[manager owner])
  end

  def group_member?(group)
    !!user&.memberships&.exists?(group: group)
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise NoMethodError, "You must define #resolve in #{self.class}"
    end

    private

    attr_reader :user, :scope
  end
end
