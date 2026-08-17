# One-off handle maintenance, run by hand AFTER the deploy that lands
# HandleName — deliberately not migrations.
#
# Three reasons none of this is a migration:
#
#   * `ginger rollback` swaps the image and does not run `down` migrations, so
#     a rename buried in one could not be undone by rolling back anyway.
#   * These rename people and rewrite a registry. A migration runs itself
#     during a deploy, whether or not anyone was watching; these ask for
#     APPLY=1 and print exactly what they would do without it.
#   * A collision has to be reported and skipped, not raised — a raising
#     migration means the container never starts, under `bash -e` in
#     bin/docker-entrypoint.
#
# Run in this order, because each one clears the way for the next:
#
#   1. handles:rename            resolve known cross-namespace collisions
#   2. handles:underscores_to_hyphens
#   3. handles:backfill_domains  rebuild the registry from the result
namespace :handles do
  def apply? = ENV["APPLY"] == "1"

  def announce(what)
    puts apply? ? "APPLYING — #{what}" : "DRY RUN — #{what} (set APPLY=1 to write)"
  end

  # Rename one specific record, through the model, so the registry follows.
  #
  #   bin/rails "handles:rename[User,infinitacity,infinita-city]"
  #
  # Generic rather than a hardcoded list: the one case that needs it today is
  # a judgement about two real accounts (a user and a group have both been
  # called "infinitacity" since 2025 — the user registered first and holds the
  # registry row, and the decision was that the GROUP keeps the name), and
  # baking somebody's handle into the repository would not make that decision
  # any more reviewable.
  desc "Rename one handle: handles:rename[Model,from,to] (APPLY=1 to write)"
  task :rename, %i[model from to] => :environment do |_t, args|
    model = { "User" => User, "Group" => Group }[args[:model]]
    raise "model must be User or Group" unless model
    announce("rename #{args[:model]} #{args[:from]} -> #{args[:to]}")

    record = model.find_by(name: args[:from])
    if record.nil?
      puts "  no #{args[:model]} named #{args[:from]}"
      next
    end

    unless apply?
      puts "  would rename #{record.id}"
      next
    end

    # update!, not update_columns: this one SHOULD go through validation and
    # the after_save that moves the registry row, which is the whole point of
    # doing it here rather than in psql.
    record.update!(name: args[:to])
    puts "  renamed #{record.id} -> #{record.reload.name}"
  end

  desc "Rename user/group handles containing '_' to use '-' (APPLY=1 to write)"
  task underscores_to_hyphens: :environment do
    announce("convert underscores to hyphens")

    [ User, Group ].each do |model|
      rows = model.where("name LIKE ?", "%\\_%").order(:name).to_a
      puts "\n#{model.name}: #{rows.size} with an underscore"

      rows.each do |record|
        target = record.name.tr("_", "-")

        # Both columns are uniquely indexed, and so is the registry. A taken
        # target is a failed write, not a silent merge — skipped and reported,
        # because which of the two rows keeps the name is a question for a
        # person.
        if model.where(name: target).where.not(id: record.id).exists? ||
           Domain.where(name: target).where.not(item_type: model.name, item_id: record.id).exists?
          puts "  SKIP  #{record.name} -> #{target} (already taken)"
          next
        end

        unless target.match?(HandleName::FORMAT)
          puts "  SKIP  #{record.name} -> #{target} (#{HandleName::FORMAT_MESSAGE})"
          next
        end

        puts "  #{apply? ? 'RENAME' : 'would'} #{record.name} -> #{target}"
        next unless apply?

        # update_columns, not update!: these rows may be non-conforming in
        # OTHER ways (a group shorter than six characters), and the point here
        # is the underscore, not to hold a rename hostage to a rule that was
        # never applied when the name was chosen. The registry is rebuilt by
        # backfill_domains afterwards, which is why that step comes last.
        begin
          record.update_columns(name: target)
        rescue ActiveRecord::RecordNotUnique
          # Claimed between the check above and the write. One row's problem,
          # not the whole run's.
          puts "  FAILED #{record.name} -> #{target} (taken concurrently)"
        end
      end
    end

    puts "\nDone.#{apply? ? '' : ' Nothing was written.'}"
  end

  # `domains` is the registry that makes users and groups share ONE handle
  # namespace. sails maintained it; soon stopped at the 2026-07-29 cutover and
  # nothing noticed, because nothing reads the table — 112 users have no row,
  # 65 groups have none, and 42 rows name something their owner is no longer
  # called. HandleName writes it again from now on; this rebuilds what was
  # missed.
  #
  # Wrong rows are deleted before missing ones are inserted, rather than
  # updated in place. A stale row holding "alice" for somebody now called
  # "bob" would otherwise block the real "alice" from being inserted, and
  # whether it does would depend on the order rows happened to be processed
  # in. Deleting first makes the outcome the same either way.
  desc "Rebuild the domains handle registry from users and groups (APPLY=1 to write)"
  task backfill_domains: :environment do
    announce("rebuild the handle registry")

    live = {}
    User.where.not(name: nil).pluck(:id, :name).each { |id, name| live[[ "User", id ]] = name }
    Group.where.not(name: nil).pluck(:id, :name).each { |id, name| live[[ "Group", id ]] = name }

    # Partitioned in one pass, and BOTH sides are used below. Deriving "which
    # items still have a row" by subtracting the stale items from all items
    # would be wrong: production has items holding two rows (a merge, or an
    # older rename that inserted rather than updated — "henrich" and
    # "henrichai" are the same account), and subtracting drops such an item
    # even though its good row survives. That mistake only showed up in the
    # dry run, which recomputed from the database after deleting and so told
    # the truth while the preview invented 42 conflicts. A preview that
    # disagrees with the run is worse than no preview.
    rows = Domain.pluck(:id, :item_type, :item_id, :name)
    stale, keep = rows.partition { |_id, type, item_id, name| live[[ type, item_id ]] != name }

    puts "\n#{stale.size} rows are wrong, orphaned or duplicated"
    stale.first(10).each { |_id, type, item_id, name| puts "  DELETE #{name} (#{type} #{item_id})" }
    puts "  … and #{stale.size - 10} more" if stale.size > 10
    Domain.where(id: stale.map(&:first)).delete_all if apply?

    taken = keep.map(&:last).to_set
    have = keep.map { |_id, type, item_id, _name| [ type, item_id ] }.to_set

    created = 0
    conflicts = []
    live.each do |(type, item_id), name|
      next if have.include?([ type, item_id ])

      # The one case this cannot decide: two records that have both been called
      # the same thing since long before the registry lapsed. Reported, never
      # resolved — see handles:rename.
      if taken.include?(name)
        conflicts << [ type, item_id, name ]
        next
      end

      taken << name
      created += 1
      next unless apply?

      Domain.create!(
        item_type: type, item_id: item_id, name: name,
        fullname: "#{name}.#{ENV.fetch('APP_HOST', 'sola.day').sub(/\Awww\./, '')}"
      )
    end

    puts "\n#{apply? ? 'created' : 'would create'} #{created} rows"
    if conflicts.any?
      puts "\n#{conflicts.size} handle(s) claimed by two records — NOT resolved:"
      conflicts.each { |type, item_id, name| puts "  #{name} (#{type} #{item_id} gets no row)" }
    end

    puts "\nDone.#{apply? ? '' : ' Nothing was written.'}"
  end
end
