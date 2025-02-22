class LeaderboardUpdateJob < ApplicationJob
  queue_as :default
  BATCH_SIZE = 100

  include GoodJob::ActiveJobExtensions::Concurrency

  # Limits concurrency to 1 job per date
  good_job_control_concurrency_with(
    key: -> { arguments.first || Date.current.to_s },
    total: 1,
    drop: true
  )

  def perform(date = Date.current)
    leaderboard = Leaderboard.create!(start_date: date)

    # Get list of valid user IDs from our database
    valid_user_ids = User.pluck(:slack_uid)
    return if valid_user_ids.empty?

    ActiveRecord::Base.transaction do
      valid_user_ids.each_slice(BATCH_SIZE) do |batch_user_ids|
        user_durations = Heartbeat.connection.select_all(<<-SQL).to_a
          WITH time_diffs AS (
            SELECT#{' '}
              user_id,
              CASE
                WHEN LAG(time) OVER (PARTITION BY user_id ORDER BY time) IS NULL THEN 0
                ELSE LEAST(
                  EXTRACT(EPOCH FROM (time - LAG(time) OVER (PARTITION BY user_id ORDER BY time))),
                  #{Heartbeat::TIMEOUT_DURATION.to_i}
                )
              END as diff_seconds
            FROM heartbeats
            WHERE DATE(time) = '#{date}'
              AND user_id IN ('#{batch_user_ids.join("','")}')
          )
          SELECT#{' '}
            user_id,
            SUM(diff_seconds)::integer as total_seconds
          FROM time_diffs
          GROUP BY user_id
          HAVING SUM(diff_seconds) > 0
        SQL

        entries_data = user_durations.map do |row|
          {
            leaderboard_id: leaderboard.id,
            user_id: row["user_id"],
            total_seconds: row["total_seconds"]
          }
        end

        # Batch insert new entries for this batch
        LeaderboardEntry.insert_all!(entries_data) if entries_data.any?
      end
    end

    # Set finished_generating_at after successful completion
    leaderboard.finished_generating_at = Time.current
    leaderboard.save!

    # Delete previous leaderboard entries from today
    Leaderboard.where.not(id: leaderboard.id).where(start_date: date).where(deleted_at: nil).update_all(deleted_at: Time.current)
  rescue => e
    Rails.logger.error "Failed to update current leaderboard: #{e.message}"
    raise
  end
end
