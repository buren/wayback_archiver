require 'spec_helper'
require 'stringio'
require 'wayback_archiver/progress_renderer'

RSpec.describe WaybackArchiver::ProgressRenderer do
  let(:stdout) { StringIO.new }
  let(:renderer) { described_class.new(stdout, terminal_width: 80) }

  def output
    stdout.string
  end

  # Strip ANSI escape sequences for easier assertion
  def clean_output
    output.gsub(/\e\[[0-9;]*[A-Za-z]/, '')
  end

  describe '#set_total' do
    it 'sets the total URL count' do
      renderer.set_total(100)
      renderer.start
      renderer.repaint

      expect(clean_output).to include('0/100')
    end
  end

  describe '#print_result' do
    before do
      renderer.set_total(10)
      renderer.start
    end

    it 'prints the result line and repaints footer' do
      renderer.print_result('  [1]  ok      http://example.com  21.5s')

      expect(clean_output).to include('[1]  ok')
      expect(clean_output).to include('http://example.com')
    end

    it 'renders footer after the result line' do
      renderer.print_result('  [1]  ok      http://example.com')

      lines = clean_output.split("\n")
      # Result line should appear before the footer
      result_idx = lines.index { |l| l.include?('http://example.com') }
      footer_idx = lines.index { |l| l.include?('0/10') }
      expect(result_idx).to be < footer_idx
    end
  end

  describe '#record_completion' do
    before do
      renderer.set_total(10)
      renderer.start
    end

    it 'returns the incremented completion count' do
      expect(renderer.record_completion(errored: false)).to eq(1)
      expect(renderer.record_completion(errored: false)).to eq(2)
    end

    it 'tracks failed count' do
      renderer.record_completion(errored: true)
      renderer.repaint

      expect(clean_output).to include('1 failed')
    end

    it 'updates the completed count in footer' do
      renderer.record_completion(errored: false)
      renderer.repaint

      expect(clean_output).to include('1/10')
    end
  end

  describe '#update_progress' do
    before do
      renderer.set_total(10)
      renderer.start
    end

    it 'updates pending count and sets state to Polling' do
      renderer.update_progress(pending: 5)

      expect(clean_output).to include('5 pending')
      expect(clean_output).to include('Polling...')
    end
  end

  describe '#set_state' do
    before do
      renderer.set_total(10)
      renderer.start
    end

    it 'changes the status line' do
      renderer.set_state('Waiting for available slots...')

      expect(clean_output).to include('Waiting for available slots...')
    end

    it 'does not repaint when state has not changed' do
      renderer.set_state('Submitting...')
      before_output = output.dup
      renderer.set_state('Submitting...')

      expect(output).to eq(before_output)
    end
  end

  describe '#finish' do
    before do
      renderer.set_total(10)
      renderer.start
      renderer.repaint
    end

    it 'clears the footer' do
      renderer.finish

      # Should contain ANSI sequences to move up and clear lines
      expect(output).to include("\e[A")
    end
  end

  describe 'progress bar rendering' do
    it 'shows a progress bar when terminal is wide enough' do
      renderer.set_total(6)
      renderer.start
      3.times { renderer.record_completion(errored: false) }
      renderer.repaint

      expect(clean_output).to include('█')
      expect(clean_output).to include('░')
      expect(clean_output).to include('3/6')
      expect(clean_output).to include('(50%)')
    end

    it 'omits the progress bar on narrow terminals' do
      narrow_renderer = described_class.new(stdout, terminal_width: 40)
      narrow_renderer.set_total(100)
      narrow_renderer.start
      narrow_renderer.repaint

      expect(clean_output).to include('0/100')
      expect(clean_output).not_to include('█')
      expect(clean_output).not_to include('░')
    end

    it 'shows 0% at the start' do
      renderer.set_total(425)
      renderer.start
      renderer.repaint

      expect(clean_output).to include('0/425 (0%)')
    end

    it 'shows 100% when all complete' do
      renderer.set_total(5)
      renderer.start
      5.times { renderer.record_completion(errored: false) }
      renderer.repaint

      expect(clean_output).to include('5/5 (100%)')
    end
  end

  describe 'ETA estimation' do
    it 'does not show ETA before 5 completions' do
      renderer.set_total(100)
      renderer.start
      4.times { renderer.record_completion(errored: false) }
      renderer.repaint

      expect(clean_output).not_to include('left')
    end

    it 'uses SPN2 rate limit (12 URLs/min) before 20 completions' do
      renderer.set_total(100)
      renderer.start
      5.times { renderer.record_completion(errored: false) }
      renderer.repaint

      expect(clean_output).to include('12.0 URLs/min')
    end

    it 'switches to EMA-based rate after 20 completions' do
      renderer.set_total(100)
      renderer.start
      20.times { renderer.record_completion(errored: false) }

      # Seed EMA as if URLs took 20s each (3 URLs/min)
      renderer.instance_variable_set(:@ema_seconds_per_url, 20.0)
      renderer.repaint

      expect(clean_output).to include('3.0 URLs/min')
    end
  end

  describe 'format_duration' do
    it 'formats seconds' do
      expect(renderer.send(:format_duration, 45)).to eq('45s')
    end

    it 'formats minutes' do
      expect(renderer.send(:format_duration, 180)).to eq('3 min')
    end

    it 'formats hours and minutes' do
      expect(renderer.send(:format_duration, 5400)).to eq('1h 30m')
    end
  end

  describe 'thread safety' do
    it 'handles concurrent record_completion calls' do
      renderer.set_total(100)
      renderer.start

      threads = 10.times.map do
        Thread.new { renderer.record_completion(errored: false) }
      end
      threads.each(&:join)

      expect(renderer.instance_variable_get(:@completed)).to eq(10)
    end

    it 'handles concurrent print_result calls' do
      renderer.set_total(100)
      renderer.start

      threads = 5.times.map do |i|
        Thread.new { renderer.print_result("  [#{i + 1}]  ok  http://example.com/#{i}") }
      end
      threads.each(&:join)

      5.times do |i|
        expect(clean_output).to include("http://example.com/#{i}")
      end
    end
  end
end
