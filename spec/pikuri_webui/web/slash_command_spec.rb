# frozen_string_literal: true

RSpec.describe PikuriWebUI::Web::SlashCommand do
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

  describe '.catalog' do
    it 'offers /model only when there is more than one connection to pick between' do
      refute_includes described_class.catalog(connections: 1).map(&:name), '/model'
      assert_includes described_class.catalog(connections: 2).map(&:name), '/model'
    end

    it 'drops nothing else on the way' do
      assert_equal described_class::CATALOG.size - 1, described_class.catalog(connections: 1).size
      assert_equal described_class::CATALOG, described_class.catalog(connections: 2)
    end
  end
end
