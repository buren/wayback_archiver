require 'spec_helper'

RSpec.describe WaybackArchiver::HTTPCode do
  describe '::type' do
    [
      # argument, expected
      [200, :success],
      ['200', :success],
      ['301', :redirect],
      ['302', :redirect],
      ['400', :error],
      ['404', :error],
      ['500', :error],
      ['503', :error],
      ['999', :unknown]
    ].each do |data|
      code, expected = data

      it "returns #{expected} for #{code} code" do
        expect(described_class.type(code)).to eq(expected)
      end
    end
  end

  describe '::success?' do
    it 'returns true when code is success' do
      code = '200'
      expect(described_class.success?(code)).to eq(true)
    end

    it 'returns false when code is not success' do
      code = '300'
      expect(described_class.success?(code)).to eq(false)
    end
  end

  describe '::error?' do
    it 'returns true when code is 400 error' do
      code = '400'
      expect(described_class.error?(code)).to eq(true)
    end

    it 'returns true when code is 500 error' do
      code = '500'
      expect(described_class.error?(code)).to eq(true)
    end

    it 'returns false when code is not error' do
      code = '200'
      expect(described_class.error?(code)).to eq(false)
    end
  end

  describe '::redirect?' do
    it 'returns true when code is redirect' do
      code = '300'
      expect(described_class.redirect?(code)).to eq(true)
    end

    it 'returns false when code is not redirect' do
      code = '200'
      expect(described_class.redirect?(code)).to eq(false)
    end
  end
end
