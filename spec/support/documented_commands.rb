require 'shellwords'

# Runs the `wayback_archiver` command lines that appear in the README and in
# examples/*.sh, exactly as they are written there.
#
# The commands are extracted from the documents rather than transcribed, so a
# flag that is renamed or removed fails the specs in whichever document still
# advertises it.
module DocumentedCommands
  # Shell commands allowed on the producing side of a pipe. The text comes
  # from this repository's own docs, but a smoke test should never become a
  # way for a documentation edit to run something arbitrary in CI.
  PIPE_PRODUCERS = %w[cat grep echo sort head tail].freeze

  # @return [Array<String>] one entry per documented invocation, in document
  #   order, with backslash continuations joined.
  def documented_commands(path)
    text = File.read(path).gsub(/\\\n\s*/, ' ')
    text.lines.filter_map do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')
      next unless invocation?(line)

      line
    end
  end

  # Execute one documented command line against the in-process CLI.
  # Handles the two shell features the docs actually use: a `>` redirect and a
  # single producer piped into wayback_archiver.
  # @return [Array(String, String, CLIHelper::ExitStatus)]
  def run_documented_command(line, dir:)
    Dir.chdir(dir) do
      tokens = Shellwords.split(line)
      redirect = nil

      if (index = tokens.index('>'))
        redirect = tokens[index + 1]
        tokens = tokens[0...index]
      end

      stdin_data = nil
      if (index = tokens.rindex('|'))
        producer = tokens[0...index]
        raise "Unsupported pipeline producer in #{line.inspect}" unless PIPE_PRODUCERS.include?(producer.first)

        stdin_data = `#{Shellwords.join(producer)}`
        tokens = tokens[(index + 1)..]
      end

      raise "Not a wayback_archiver invocation: #{line.inspect}" unless tokens.shift == 'wayback_archiver'

      stdout, stderr, status = run_cli(*tokens, stdin_data: stdin_data)
      File.write(redirect, stdout) if redirect
      [stdout, stderr, status]
    end
  end

  # The files the documented commands read. Written into a fresh directory per
  # example so one command can never depend on another's leftovers, except in
  # the pipeline specs that deliberately run commands in sequence.
  def write_documented_inputs!(dir)
    File.write(File.join(dir, 'urls.txt'), <<~URLS)
      # Production pages
      https://example.com/
      https://example.com/about

      # Blog posts
      https://example.com/blog/post-1
    URLS
    File.write(File.join(dir, 'all_urls.txt'), "https://example.com/\nhttps://other.invalid/\n")
    File.write(File.join(dir, 'list1.txt'), "https://example.com/\n")
    File.write(File.join(dir, 'list2.txt'), "https://example.com/about\n")
    File.write(File.join(dir, 'seeds.txt'), "https://example.com/\n")
    File.write(File.join(dir, 'session.jsonl'), <<~SESSION)
      {"url":"https://example.com/","success":true,"timestamp":"20260326120000","job_id":"spn2-job-0","status_ext":null,"recorded_at":"2026-03-26T12:00:00Z"}
    SESSION
  end

  private

  def invocation?(line)
    last_segment = Shellwords.split(line).rindex('|')&.then { |i| Shellwords.split(line)[i + 1] }
    last_segment ||= Shellwords.split(line).first
    last_segment == 'wayback_archiver'
  rescue ArgumentError
    false # unbalanced quotes: prose, not a command
  end
end
