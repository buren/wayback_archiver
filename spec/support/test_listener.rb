require 'wayback_archiver/listener'

module WaybackArchiver
  class TestListener < NullListener
    attr_reader :resolved_events, :submitted_events, :completed_events,
                :progress_events, :waiting_for_slots_events, :batch_start_events

    def initialize
      @resolved_events = []
      @submitted_events = []
      @completed_events = []
      @progress_events = []
      @waiting_for_slots_events = []
      @batch_start_events = []
    end

    def on_resolved(strategy:, url_count:, source:)
      @resolved_events << { strategy: strategy, url_count: url_count, source: source }
    end

    def on_submitted(url:, job_id:)
      @submitted_events << { url: url, job_id: job_id }
    end

    def on_completed(result:)
      @completed_events << { result: result }
    end

    def on_progress(captured:, failed:, pending:)
      @progress_events << { captured: captured, failed: failed, pending: pending }
    end

    def on_waiting_for_slots(processing:)
      @waiting_for_slots_events << { processing: processing }
    end

    def on_batch_start(total:)
      @batch_start_events << { total: total }
    end
  end
end
