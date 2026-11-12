# frozen_string_literal: true

# The seam public/js/*.js sits on, checked from the Ruby side.
#
# Nothing here runs JavaScript. There is no JS runtime in this suite and
# +D_no_js_build_step+ keeps it that way, so this reads the scripts as text and
# asserts that every name they hard-code still exists on the server's side of
# the line: element ids, <template> ids, routes, CSS hooks, command names.
#
# The *protocol* is all this checks. How the client source is split across
# files is the client's own business (+D_feature_owns_its_file+) and no
# assertion here has an opinion on it — which is why the scan is over every
# script that may name a server-side name, joined, rather than over app.js.
#
# That is the failure this covers, and the reason it is worth a spec of its
# own. Renaming an id in index.erb, a route in app.rb or a command in
# SlashCommand leaves both files individually correct and every other spec
# green, while the page silently loses a control — +getElementById+ just
# returns null, and no exception reaches anything that is watching. The Ruby
# specs pin what the server renders; a browser would pin what the script does;
# the *agreement* between them had nothing.
#
# Only literals are visible to a reader like this, and that is by construction:
# app.js's +getElementById(id)+ over a block id, and +fetch(e.target.action)+
# over the delete form's own action, name nothing to check.
RSpec.describe 'the client/server contract' do
  root = Pathname(__dir__).join('../..').expand_path
  # Every script, globbed rather than listed: a named list would quietly shrink
  # the protocol check the next time a feature moves out of app.js, which is the
  # one thing D_feature_owns_its_file asks of this file. dom.js joins in and
  # contributes nothing, since it names no id, template or route.
  client_js = Pathname.glob(root / 'public/js/*.js').sort.map(&:read).join("\n")
  index_erb = (root / 'views/index.erb').read
  sidebar_erb = (root / 'views/_sidebar.erb').read

  it 'reaches only for element ids index.erb renders' do
    ids = client_js.scan(/getElementById\(['"]([\w-]+)['"]\)/).flatten.uniq
    refute_empty ids, 'the id scan found nothing — the client changed shape, fix the pattern'

    missing = ids.reject { |id| index_erb.include?(%(id="#{id}")) }
    assert_equal [], missing, "the client reaches for #{missing.join(', ')}; index.erb renders no such id"
  end

  it 'clones only templates index.erb defines' do
    names = client_js.scan(/cloneTemplate\(['"]([\w-]+)['"]\)/).flatten.uniq
    refute_empty names, 'the template scan found nothing — the client changed shape, fix the pattern'

    missing = names.reject { |name| index_erb.include?(%(<template id="#{name}">)) }
    assert_equal [], missing, "the client clones #{missing.join(', ')}; index.erb defines no such <template>"
  end

  # Both the fetches and the EventSource: a route this shell no longer answers
  # is the same bug whichever verb reaches for it.
  it 'calls only routes the app answers' do
    paths = client_js.scan(/(?:fetch|new EventSource)\(\s*['"`](\/[^'"`?${]*)/).flatten.uniq
    refute_empty paths, 'the route scan found nothing — the client changed shape, fix the pattern'

    patterns = PikuriWebUI::Web::App.routes.values.flatten(1).map(&:first)
    missing = paths.reject { |path| patterns.any? { |pattern| pattern.match(path) } }
    assert_equal [], missing, "the client calls #{missing.join(', ')}; App has no route matching"
  end

  it 'queries only classes the templates render' do
    classes = client_js.scan(/querySelector(?:All)?\(['"]\.([\w-]+)['"]\)/).flatten.uniq
    refute_empty classes, 'the class scan found nothing — the client changed shape, fix the pattern'

    markup = index_erb + sidebar_erb
    missing = classes.reject { |name| markup.include?(name) }
    assert_equal [], missing, "the client queries .#{missing.join(', .')}; no template renders it"
  end

  # The mark that decides whether deleting navigates: app.js reads it off the
  # row rather than off the URL, so the two spellings have to agree.
  it 'tests for the row mark _sidebar.erb writes' do
    assert_includes client_js, "classList.contains('current')"
    assert_includes sidebar_erb, "' current' if c[:current]"
  end

  # A mismatch drops every stream frame silently: the client finds no marker,
  # skips the diff, and the reply appears only when the bookend lands.
  it 'looks for the streaming marker StreamingMessage writes' do
    texts = client_js.scan(/COMMENT_NODE && node\.data === '([^']*)'/).flatten.uniq
    assert_equal ["<!--#{texts.first}-->"], [PikuriWebUI::Web::StreamingMessage::MARKER]
    assert_equal 1, texts.size
  end

  # A mistyped path here is not a subtle bug: the module never loads and the
  # page is inert, with nothing but a console error nobody is watching.
  it 'imports only sibling modules that exist' do
    specifiers = client_js.scan(%r{^import .*? from '\./([\w.-]+)';}).flatten.uniq
    refute_empty specifiers, 'the import scan found nothing — the client changed shape, fix the pattern'

    missing = specifiers.reject { |name| (root / 'public/js' / name).exist? }
    assert_equal [], missing, "the client imports ./#{missing.join(', ./')}; public/js/ has no such file"
  end

  # Strings the server renders into the page *and* app.js rewrites over the top
  # of when SSE updates it. Reword one side only and the label silently changes
  # the first time a frame lands — the page contradicts itself mid-turn.
  it 'agrees with index.erb on the labels both of them write' do
    [
      'waiting for a free slot',  # the queued state, status-state
      ' queued',                  # the pending count, status-pending
      '☀ light',                  # the theme toggle, both directions
      '☾ dark'
    ].each do |label|
      assert_includes client_js, label, "the client no longer writes #{label.inspect}"
      assert_includes index_erb, label, "index.erb no longer renders #{label.inspect}"
    end
  end

  # The three-place contract SlashCommand's rdoc describes. The catalog and the
  # <template>s each have a spec of their own; this is the third place, the one
  # that lives in a file no Ruby spec loads.
  #
  # Against CATALOG rather than .catalog: the arm has to exist even in a
  # single-connection config, which drops /model from the palette but leaves
  # the map app.js hands the composer exactly as it is.
  it 'arms every catalogued command in the composer it configures, and none besides' do
    arms = client_js.scan(%r{^\s*'(/[\w-]+)':}).flatten
    assert_equal PikuriWebUI::Web::SlashCommand::CATALOG.map(&:name).sort, arms.sort
  end
end
