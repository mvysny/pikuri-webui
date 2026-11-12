# frozen_string_literal: true

RSpec.describe PikuriWebUI::Util::RelativeTime do
  let(:now) { Time.utc(2026, 8, 27, 12, 0, 0) }

  def ago(seconds) = described_class.humanize(now - seconds, now: now)

  it 'calls anything under two minutes just now' do
    assert_equal 'just now', ago(0)
    assert_equal 'just now', ago(119)
  end

  it 'reads a clock-skewed future stamp as just now, not a negative count' do
    assert_equal 'just now', ago(-600)
  end

  it 'counts whole minutes, hours and days' do
    assert_equal '2 minutes ago', ago(120)
    assert_equal '59 minutes ago', ago(3599)
    assert_equal '1 hour ago', ago(3600)
    assert_equal '23 hours ago', ago(86_399)
    assert_equal '1 day ago', ago(86_400)
    assert_equal '29 days ago', ago(29 * 86_400)
  end

  it 'truncates rather than rounds, so a stamp never reads older than it is' do
    assert_equal '1 hour ago', ago(7199)
  end

  it 'switches to an absolute date past a month' do
    assert_equal (now - 30 * 86_400).getlocal.strftime('%Y-%m-%d'), ago(30 * 86_400)
  end
end
