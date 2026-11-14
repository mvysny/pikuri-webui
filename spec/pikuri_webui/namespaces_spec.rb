# frozen_string_literal: true

# Guards the one-way rule of D_namespaces: the service namespaces may not name
# anything under Web. Parses rather than greps, so a class named in a doc
# comment — Agents::Runner documents its injected collaborators by type — is
# not a violation, and a string mentioning one is not either.
RSpec.describe 'namespace dependency direction' do
  SERVICE_DIRS = %w[agents conversations].freeze

  # Web's own constants plus the namespace itself, so a bare `Transcript` and a
  # qualified `Web::Transcript` are both caught. Read off the module, so a class
  # added to Web is covered without touching this list.
  def web_names = (PikuriWebUI::Web.constants + [:Web]).to_set

  # Every constant name the file references, at any depth. COLON2 carries the
  # scope as a child node, so walking children alone reaches both halves of
  # `Web::App`.
  def constants_in(path)
    found = Set.new
    walk = lambda do |node|
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      found << node.children.last if %i[CONST COLON2].include?(node.type)
      node.children.each { |child| walk.call(child) }
    end
    walk.call(RubyVM::AbstractSyntaxTree.parse_file(path))
    found
  end

  def service_files
    SERVICE_DIRS.flat_map { |dir| Dir[File.expand_path("../../lib/pikuri_webui/#{dir}/**/*.rb", __dir__)] }
  end

  it 'finds the service files it is supposed to be guarding' do
    # Without this the suite would pass vacuously if the tree were rearranged.
    assert_operator service_files.size, :>=, 5
  end

  it 'never names a Web constant from Agents or Conversations' do
    offenders = service_files.filter_map do |path|
      named = constants_in(path) & web_names
      "#{path.delete_prefix("#{Dir.pwd}/")}: #{named.to_a.sort.join(', ')}" if named.any?
    end

    assert_empty offenders,
                 "service code may not name Web (D_namespaces); inject the collaborator instead:\n" \
                 "#{offenders.join("\n")}"
  end
end
