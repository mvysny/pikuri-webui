# frozen_string_literal: true

RSpec.describe PikuriWebUI::Web::Disclosure do
  let(:wrapped) { described_class.wrap('<p>The user wants…</p>') }

  it 'wraps reasoning in an open disclosure, the stored form' do
    assert_equal '<details open><summary>thinking</summary><p>The user wants…</p></details>', wrapped
  end

  it 'collapses exactly what wrap produced' do
    assert_equal '<details><summary>thinking</summary><p>The user wants…</p></details>',
                 described_class.collapse(wrapped)
  end

  # A page render maps every block through collapse without asking its kind,
  # and a user's own `<details open>` inside a rendered message is theirs.
  it 'leaves any other block alone' do
    ['hello there', '<p>general kenobi</p>', '<p>x</p><details open><summary>thinking</summary>'].each do |html|
      assert_equal html, described_class.collapse(html)
    end
  end

  it 'closes only the wrapper, never a disclosure the reasoning itself contains' do
    inner = described_class.wrap('<details open><summary>aside</summary>x</details>')
    assert_equal '<details><summary>thinking</summary><details open><summary>aside</summary>x</details></details>',
                 described_class.collapse(inner)
  end
end
