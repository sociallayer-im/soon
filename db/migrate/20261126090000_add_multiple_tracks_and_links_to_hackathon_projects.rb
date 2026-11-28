class AddMultipleTracksAndLinksToHackathonProjects < ActiveRecord::Migration[8.1]
  FIELDS = {
    track_ids: :track_id,
    repo_links: :repo_url,
    demo_links: :demo_url,
    video_links: :video_url
  }.freeze

  def up
    FIELDS.each do |field, legacy|
      add_column :hackathon_projects, field, :string, array: true, default: [], null: false
      execute <<~SQL
        UPDATE hackathon_projects
        SET #{field} = ARRAY[#{legacy}]::varchar[]
        WHERE NULLIF(BTRIM(#{legacy}), '') IS NOT NULL
      SQL
    end
    add_index :hackathon_projects, :track_ids, using: :gin
  end

  def down
    remove_index :hackathon_projects, :track_ids
    FIELDS.each_key { |field| remove_column :hackathon_projects, field }
  end
end
