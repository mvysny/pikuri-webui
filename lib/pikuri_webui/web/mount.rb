# frozen_string_literal: true

module PikuriWebUI
  module Web
    # Rack middleware serving the whole app under one path, the +[web]
    # base_path+ — a servlet's context root:
    #
    #   PikuriWebUI::Web::App.use PikuriWebUI::Web::Mount, '/pikuri-webui'
    #
    #   GET /pikuri-webui/c/42   # → the app, SCRIPT_NAME "/pikuri-webui", PATH_INFO "/c/42"
    #   GET /pikuri-webui        # → the app's "/", SCRIPT_NAME "/pikuri-webui", PATH_INFO ""
    #   GET /c/42                # → 404, saying where the app lives
    #
    # Moving the prefix into +SCRIPT_NAME+ is the whole trick: Sinatra's +to+,
    # +url+ and +redirect+ prepend it, and {Gate} scopes its cookie by it. What
    # no request can tell — an attachment URL rendered on a turn thread, a
    # script's +fetch+ — reads +[web] base_path+ instead.
    #
    # A request without the prefix is refused rather than taken as one a proxy
    # stripped, so one URL always means one thing (+D_base_path_mount+). The
    # refusal is plain text naming the fix, since its likeliest reader is
    # someone whose proxy just did that. Never a redirect back to the prefix:
    # behind a proxy that strips, that loops.
    #
    # Mounted outside {Gate}, so the gate sees the prefix and a misrouted
    # request is answered before anyone is asked for a password.
    #
    # Immutable.
    class Mount
      # @param app [#call] the Rack app to mount.
      # @param path [String] the prefix, +"/pikuri-webui"+: absolute, no
      #   trailing slash — {Config#base_path}, which checked it.
      def initialize(app, path)
        @app = app
        @path = path
        freeze
      end

      # @param env [Hash] the Rack environment.
      # @return [Array(Integer, Hash, #each)] the app's response, or a 404 for a
      #   path outside the prefix.
      def call(env)
        path_info = env['PATH_INFO'].to_s
        rest = path_info.delete_prefix(@path)
        return outside unless rest.length < path_info.length && (rest.empty? || rest.start_with?('/'))

        @app.call(env.merge('SCRIPT_NAME' => "#{env['SCRIPT_NAME']}#{@path}", 'PATH_INFO' => rest))
      end

      private

      # @return [Array(Integer, Hash, Array<String>)] a 404 saying where the app is.
      def outside
        body = "Not found. pikuri-webui is served under #{@path}/ ([web] base_path in its config file).\n" \
               "A proxy in front that strips that prefix has to put it back on its target, e.g.\n\n" \
               "  tailscale serve --set-path #{@path} http://127.0.0.1:<port>#{@path}\n"
        [404, { 'content-type' => 'text/plain; charset=utf-8', 'x-content-type-options' => 'nosniff' }, [body]]
      end
    end
  end
end
