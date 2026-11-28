class AddDiscoverySignals < ActiveRecord::Migration[8.1]
  def up
    add_column :groups, :browse_city, :string
    add_column :groups, :discovery_active_at, :datetime
    execute <<~SQL
      UPDATE groups SET browse_city = CASE lower(regexp_replace(btrim(city), '市$', ''))
        WHEN 'shanghai' THEN '上海' WHEN 'beijing' THEN '北京' WHEN 'hangzhou' THEN '杭州'
        WHEN 'shenzhen' THEN '深圳' WHEN 'guangzhou' THEN '广州' WHEN 'chengdu' THEN '成都'
        WHEN 'dali' THEN '大理' ELSE NULLIF(lower(regexp_replace(btrim(city), '市$', '')), '') END
    SQL
    execute <<~SQL
      UPDATE groups SET discovery_active_at = signals.latest
      FROM (SELECT group_id, MAX(created_at) AS latest FROM (
        SELECT group_id, created_at FROM events WHERE status = 'published' AND visibility IN ('normal','open_registration')
        UNION ALL
        SELECT topics.group_id, topics.created_at FROM topics JOIN categories ON categories.id = topics.category_id
        WHERE topics.deleted_at IS NULL AND topics.flagged_at IS NULL AND topics.sync_to_community = true
          AND categories.visibility = 'public' AND categories.archived = false
          AND (topics.event_id IS NULL OR topics.event_id IN (SELECT id FROM events WHERE status = 'published' AND visibility IN ('normal','open_registration')))
      ) contributions GROUP BY group_id) signals WHERE groups.id = signals.group_id
    SQL
  end
  def down
    remove_column :groups, :discovery_active_at
    remove_column :groups, :browse_city
  end
end
