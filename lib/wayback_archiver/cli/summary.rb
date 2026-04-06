require 'shellwords'
require 'wayback_archiver'

module WaybackArchiver
  class CLI
    class Summary
      def initialize(stdout:, stderr:)
        @stdout = stdout
        @stderr = stderr
      end

      def print_summary(results, archive_start_time)
        tally = { succeeded: 0, submitted: 0, cached: 0, skipped: 0, failed: 0, errors: {} }
        results.each do |r|
          if r.errored?
            tally[:failed] += 1
            cat = r.error_category
            tally[:errors][cat] = (tally[:errors][cat] || 0) + 1
          elsif r.submitted?
            tally[:submitted] += 1
          elsif r.cached?
            tally[:cached] += 1
          elsif r.skipped?
            tally[:skipped] += 1
          else
            tally[:succeeded] += 1
          end
        end
        total = results.length

        @stdout.puts "\n--- Summary ---"
        breakdown = ""
        if tally[:failed] > 0
          parts = []
          parts << "#{tally[:errors][:transient]} transient" if tally[:errors][:transient]
          parts << "#{tally[:errors][:daily_limit]} daily limit" if tally[:errors][:daily_limit]
          parts << "#{tally[:errors][:permanent]} permanent" if tally[:errors][:permanent]
          parts << "#{tally[:errors][nil]} uncategorized" if tally[:errors][nil]
          breakdown = " (#{parts.join(', ')})" if parts.any?
        end
        line = "Total: #{total}  Succeeded: #{tally[:succeeded]}  Failed: #{tally[:failed]}#{breakdown}"
        line << "  Submitted: #{tally[:submitted]}" if tally[:submitted] > 0
        line << "  Cached: #{tally[:cached]}" if tally[:cached] > 0
        line << "  Skipped: #{tally[:skipped]}" if tally[:skipped] > 0
        @stdout.puts line

        wall_seconds = [1, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - archive_start_time).round(0).to_i].max
        rate = (total * 60.0 / wall_seconds).round(0)
        @stdout.puts "Duration: #{format_duration(wall_seconds)} (#{rate} URLs/min)"
      end

      def build_resume_command(options, session)
        parts = ['wayback_archiver']
        if options.file_path
          parts << "--file=#{Shellwords.shellescape(options.file_path)}"
        else
          options.urls.each { |u| parts << Shellwords.shellescape(u) }
        end
        parts << "--resume=#{Shellwords.shellescape(session.path)}"
        parts << "--#{options.strategy}"
        parts << "--concurrency=#{options.concurrency}" if options.concurrency != DEFAULT_CONCURRENCY
        parts << "--limit=#{options.limit}" if options.limit != DEFAULT_MAX_LIMIT
        options.hosts.each { |h| parts << "--hosts=#{Shellwords.shellescape(h.source)}" } if options.hosts.any?
        options.spn2_options.each do |key, value|
          flag = key.to_s.tr('_', '-')
          if value == true
            parts << "--#{flag}"
          elsif value.is_a?(Array)
            parts << "--#{flag}=#{value.join(',')}"
          elsif value
            parts << "--#{flag}=#{value}"
          end
        end
        parts.join(' ')
      end

      def print_resume_message(resume_command)
        @stderr.puts "Some URLs failed. Resume with:"
        @stderr.puts "  #{resume_command}"
      end

      def write_report(results, report_path)
        return unless report_path

        require 'wayback_archiver/report'
        Report.write(results, report_path)
        WaybackArchiver.logger.info("Report written to #{report_path}")
      end

      def startup_banner(options)
        parts = ["wayback_archiver v#{WaybackArchiver::VERSION}"]
        parts << "strategy: #{options.strategy}"
        parts << "concurrency: #{options.concurrency}"
        parts << "limit: #{options.limit}" if options.limit != DEFAULT_MAX_LIMIT
        parts << "hosts: #{options.hosts.length}" if options.hosts.any?
        parts << "skip-archived" if options.skip_archived
        parts.join(' | ')
      end

      private

      def format_duration(total_seconds)
        hours, remainder = total_seconds.divmod(3600)
        minutes, seconds = remainder.divmod(60)
        if hours > 0
          "#{hours}h #{minutes}m #{seconds}s"
        elsif minutes > 0
          "#{minutes}m #{seconds}s"
        else
          "#{seconds}s"
        end
      end
    end
  end
end
