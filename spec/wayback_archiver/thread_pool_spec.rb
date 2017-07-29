require 'spec_helper'

RSpec.describe WaybackArchiver::ThreadPool do
  context 'with concurrency less than 1' do
    it 'raises ArgumentError' do
      expect { described_class.build(0) }.to raise_error(ArgumentError)
    end
  end

  context 'with concurrency 1' do
    it 'returns a Concurrency::ImmediateExecutor' do
      thread_pool = described_class.build(1)
      expect(thread_pool).to be_an_instance_of(Concurrent::ImmediateExecutor)
    end
  end

  context 'with concurrency greater than 1' do
    it 'returns a Concurrent::FixedThreadPool' do
      thread_pool = described_class.build(2)
      expect(thread_pool).to be_an_instance_of(Concurrent::FixedThreadPool)
    end
  end
end
