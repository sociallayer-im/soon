namespace :handles do
  # One-off, run by hand AFTER the deploy that lands HandleName — deliberately
  # not a migration.
  #
  # Three reasons it is a rake task:
  #
  #   * `ginger rollback` swaps the image and does not run `down` migrations,
  #     so a rename buried in one could not be undone by rolling back anyway.
  #   * It renames people. A migration runs itself during a deploy, whether or
  #     not anyone was watching; this asks for APPLY=1 and prints exactly what
  #     it is about to do without it.
  #   * A colliding rename has to be skipped rather than crash the container on
  #     boot — which is what a raising migration would do, under `bash -e` in
  #     bin/docker-entrypoint.
  #
  #   bin/rails handles:underscores_to_hyphens           # report only
  #   APPLY=1 bin/rails handles:underscores_to_hyphens   # do it
  desc "Rename user/group handles containing '_' to use '-' (APPLY=1 to write)"
  task underscores_to_hyphens: :environment do
    apply = ENV["APPLY"] == "1"
    puts apply ? "APPLYING" : "DRY RUN — set APPLY=1 to write"

    [ User, Group ].each do |model|
      rows = model.where("name LIKE ?", "%\\_%").order(:name).to_a
      puts "\n#{model.name}: #{rows.size} with an underscore"

      rows.each do |record|
        target = record.name.tr("_", "-")

        # Both columns are uniquely indexed, so a taken target is a failed
        # write, not a silent merge. Skipped and reported: which of the two
        # rows should keep the name is a question for a person.
        if model.where(name: target).where.not(id: record.id).exists?
          puts "  SKIP  #{record.name} -> #{target} (already taken)"
          next
        end

        # Says so rather than renaming into something the validation would now
        # refuse. None exist in production today (all six live cases land
        # inside 6-20), but a name is user input and this task may be run again.
        unless target.match?(HandleName::FORMAT)
          puts "  SKIP  #{record.name} -> #{target} (#{HandleName::FORMAT_MESSAGE})"
          next
        end

        puts "  #{apply ? 'RENAME' : 'would'} #{record.name} -> #{target}"
        # update_columns, not update!: these rows may be non-conforming in
        # OTHER ways (a group shorter than six characters), and the point here
        # is the underscore, not to hold a rename hostage to a rule that was
        # never applied when the name was chosen.
        record.update_columns(name: target) if apply
      end
    end

    puts "\nDone.#{apply ? '' : ' Nothing was written.'}"
  end
end
