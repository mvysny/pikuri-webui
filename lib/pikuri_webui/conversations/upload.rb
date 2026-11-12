# frozen_string_literal: true

require 'pikuri-core'

module PikuriWebUI
  module Conversations
    # One image the user attached to a message, checked and renamed, on its way
    # to the conversation's +attachments/+ folder and to the model:
    #
    #   upload = Upload.from(filename: 'Screen Shot.PNG', bytes: png)
    #   upload.filename      # => "Screen-Shot.png"
    #   upload.stored_name   # => "3f9a1c8e2b-Screen-Shot.png"
    #   Upload.from(filename: 'notes.txt', bytes: 'hello')   # => nil
    #
    # The type is decided by the bytes, never by the name or by the browser's
    # +Content-Type+, and the extension is then *rewritten* to match it. That is
    # what keeps {#stored_name} — which becomes a URL path segment and a file
    # name — inside +[A-Za-z0-9._-]+ whatever the multipart part claimed.
    #
    # Plain on purpose, so {Web::App} can build one without naming a pikuri
    # type (`D_pikuri_free_core`); {#to_attachment} is where it crosses.
    #
    # @!attribute [r] mime
    #   @return [String] one of {TYPES}' keys, sniffed from the bytes
    # @!attribute [r] filename
    #   @return [String] the name the model is shown: the uploaded stem, made
    #     path-safe, plus the extension {TYPES} gives +mime+
    # @!attribute [r] bytes
    #   @return [String] the file's contents, binary
    Upload = Data.define(:mime, :filename, :bytes) do
      # @param filename [String, nil] the name the browser sent; only its stem
      #   survives
      # @param bytes [String] the file's contents
      # @return [Upload, nil] nil when the bytes are not an image of {TYPES}
      def self.from(filename:, bytes:)
        mime = sniff(bytes)
        return nil if mime.nil?

        stem = File.basename(filename.to_s, '.*').gsub(/[^A-Za-z0-9._-]+/, '-').delete_prefix('.')
        stem = 'image' if stem.empty?
        new(mime: mime, filename: "#{stem}#{Upload::TYPES.fetch(mime)}", bytes: bytes.b)
      end

      # The image type a file's leading bytes announce, for the four formats a
      # vision model takes.
      #
      # @param bytes [String]
      # @return [String, nil] a {TYPES} key, or nil for anything else
      def self.sniff(bytes)
        head = bytes.byteslice(0, 12).to_s.b
        if head.start_with?("\x89PNG\r\n\x1A\n".b) then 'image/png'
        elsif head.start_with?("\xFF\xD8\xFF".b) then 'image/jpeg'
        elsif head.start_with?('GIF87a', 'GIF89a') then 'image/gif'
        elsif head.start_with?('RIFF') && head.byteslice(8, 4) == 'WEBP' then 'image/webp'
        end
      end

      # The name pikuri's +History#save+ will store this image under, so a file
      # {Store#stash} wrote ahead of the turn is the one the save then skips.
      #
      # @return [String] a bare basename: ten hex digits, a dash, {#filename}
      def stored_name = to_attachment.stored_name

      # @return [Pikuri::Attachment] the same image as pikuri's type, for
      #   +run_loop+ and the Interloper
      def to_attachment = Pikuri::Attachment.new(mime: mime, filename: filename, bytes: bytes)
    end

    # The accepted image types and the extension each is stored under: PNG,
    # JPEG, GIF and WebP, the set pikuri's own +chat_attachments.rb+ takes.
    #
    # @return [Hash{String => String}]
    Upload::TYPES = {
      'image/png' => '.png', 'image/jpeg' => '.jpg', 'image/gif' => '.gif', 'image/webp' => '.webp'
    }.freeze
  end
end
