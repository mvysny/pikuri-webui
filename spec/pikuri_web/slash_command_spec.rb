# frozen_string_literal: true

RSpec.describe PikuriWeb::SlashCommand do
  describe 'CATALOG' do
    it 'names every command with a leading slash, since that is what the palette matches' do
      described_class::CATALOG.each { |command| assert command.name.start_with?('/'), command.name }
    end

    it 'holds no duplicate name, which would make a prefix resolve to two rows' do
      names = described_class::CATALOG.map(&:name)
      assert_equal names.uniq, names
    end

    it 'describes every command, because the description is the palette\'s right column' do
      described_class::CATALOG.each { |command| refute_empty command.description }
    end
  end
end
