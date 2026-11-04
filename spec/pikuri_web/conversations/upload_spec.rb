# frozen_string_literal: true

RSpec.describe PikuriWeb::Conversations::Upload do
  let(:png) { "\x89PNG\r\n\x1A\n#{'pixels' * 10}".b }

  it 'types an image by its bytes' do
    {
      png => 'image/png',
      "\xFF\xD8\xFF\xE0rest".b => 'image/jpeg',
      'GIF89a rest' => 'image/gif',
      'RIFF0000WEBPVP8 ' => 'image/webp'
    }.each { |bytes, mime| assert_equal mime, described_class.from(filename: 'x', bytes: bytes).mime }
  end

  it 'refuses anything else, whatever it is called' do
    assert_nil described_class.from(filename: 'shot.png', bytes: '<html>')
    assert_nil described_class.from(filename: 'shot.png', bytes: 'RIFF0000WAVEfmt ')
  end

  # The name becomes a file name and a URL segment, so whatever the part
  # claimed, only path-safe characters and the type's own extension survive.
  it 'keeps the stem, made safe, and gives it the extension of the type' do
    assert_equal 'Screen-Shot-1.png', described_class.from(filename: 'Screen Shot 1.JPG', bytes: png).filename
    assert_equal 'passwd.png', described_class.from(filename: '../../etc/passwd', bytes: png).filename
    assert_equal 'image.png', described_class.from(filename: nil, bytes: png).filename
    assert_match(/\A\h{10}-shot\.png\z/, described_class.from(filename: 'shot.png', bytes: png).stored_name)
  end

  it 'crosses to pikuri as the same image' do
    attachment = described_class.from(filename: 'shot.png', bytes: png).to_attachment

    assert_equal Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png), attachment
  end
end
