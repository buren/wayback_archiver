require 'spec_helper'

RSpec.describe WaybackArchiver::NullLogger do
  it 'inherits from Logger' do
    expect(described_class.ancestors).to include(Logger)
  end

  it 'can be initialized with arguments' do
    logger = described_class.new('buren')
    expect(logger.is_a?(described_class)).to eq(true)
  end

  it 'has #add method that can recieve args and a block' do
    logger = described_class.new('buren')
    expect(logger.add('buren', &:nil?)).to be_nil
  end
end
