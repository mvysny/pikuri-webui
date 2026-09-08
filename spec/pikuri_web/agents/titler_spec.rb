# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'logger'
# Opt-in test scaffolding, not part of pikuri-core's default surface.
require 'pikuri/testing'

# Drives the real titling path — a real Pikuri::Agent over pikuri's scripted
# fake transport — because the caps and the </think> strip are what stand
# between a silently-unapplied thinking-off parameter and an essay in the
# sidebar.
#
# Two things are deliberately not asserted here, because a unit spec cannot:
# that the <opener> wrapper makes an imperative opener get *titled* rather than
# obeyed, and that the system prompt yields 3-7 words. Both need a live model,
# which is what bin/probe-titler is for, and the fake records no request bodies
# to check the wrapper against anyway.
describe PikuriWeb::Agents::Titler do
  def titler(reply, params_declared: true)
    transport = Pikuri::Testing.fake_transport { |llm| llm.reply(reply) }
    described_class.new(transport: transport, params_declared: params_declared)
  end

  describe '#title_for' do
    it 'returns the model line as the title' do
      assert_equal 'Sinatra Versus Roda For SSE',
                   titler('Sinatra Versus Roda For SSE').title_for('Compare Sinatra and Roda')
    end

    it 'caps a long-winded answer at MAX_WORDS' do
      title = titler('One Two Three Four Five Six Seven Eight Nine').title_for('x')
      assert_equal 'One Two Three Four Five Six Seven', title
      assert_equal described_class::MAX_WORDS, title.split.size
    end

    # The measured failure: a thinking model dumping its reasoning into the
    # content where a title belongs. Seven words of that is still an essay.
    it 'caps at MAX_CHARS even within MAX_WORDS' do
      title = titler("#{'x' * 40} #{'y' * 60}").title_for('x')
      assert_equal described_class::MAX_CHARS, title.length
    end

    it 'keeps only the first line' do
      assert_equal 'First Line Only', titler("First Line Only\nand a second").title_for('x')
    end

    it 'drops anything up to and including a leaked reasoning close tag' do
      leaked = "<think>Let me consider the options here.</think>\nSinatra Versus Roda"
      assert_equal 'Sinatra Versus Roda', titler(leaked).title_for('x')
    end

    it 'answers nil for a reply with nothing usable in it' do
      assert_nil titler("   \n  ").title_for('x')
      assert_nil titler('</think>').title_for('x')
    end

    # Model output is text of unknown provenance whether or not anyone is
    # attacking, and the title reaches the sidebar as plain text in four places
    # where escaping stops markup but not a bidi override.
    it 'sanitizes the title rather than trusting escaping downstream' do
      title = titler("Report‮fdp.txt").title_for('x')
      refute_includes title, "‮"
    end

    # One Titler serves every conversation for the life of the process, so a
    # second call must start from nothing rather than build on the first.
    it 'is reusable: each call builds its own agent' do
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.reply('First Title')
        llm.reply('Second Title')
      end
      one = described_class.new(transport: transport, params_declared: true)

      assert_equal 'First Title', one.title_for('a')
      assert_equal 'Second Title', one.title_for('b')
    end
  end

  # The canary is diagnostic only — it never changes the title — and its level
  # follows whether the operator declared any `params`. Driven through the
  # private reporter with a genuine Tally fed a genuine Tokens event, because
  # pikuri's fake reports a fixed usage block with no reasoning tokens in it.
  describe 'the reasoning canary' do
    def tally(thinking)
      described_class::Tally.new.tap do |t|
        t.on_event(Pikuri::Agent::Event::Tokens.new(
                     input: 10, output: 8, cached: 0, cache_creation: 0,
                     thinking: thinking, model_id: 'fake'
                   ))
      end
    end

    def logged(titler, thinking)
      log = StringIO.new
      PikuriWeb.logger = Logger.new(log)
      titler.send(:report_reasoning, tally(thinking), 1.2)
      log.string
    ensure
      PikuriWeb.logger = Logger.new(File::NULL)
    end

    it 'says nothing when the model did not reason' do
      assert_empty logged(titler('t'), 0)
    end

    it 'warns when a declared params table did not take effect' do
      output = logged(titler('t', params_declared: true), 640)
      assert_includes output, 'WARN'
      assert_includes output, '`params` did not take effect'
      assert_includes output, '640 reasoning tokens'
    end

    it 'only informs when nobody asked for thinking to be off' do
      output = logged(titler('t', params_declared: false), 640)
      assert_includes output, 'INFO'
      assert_includes output, 'titles are slow'
      refute_includes output, 'did not take effect'
    end

    it 'says it once, not once per title' do
      one = titler('t', params_declared: true)
      refute_empty logged(one, 640)
      assert_empty logged(one, 640)
    end
  end

  describe described_class::Tally do
    it 'sums reasoning and output tokens across a turn, ignoring other events' do
      subject = described_class.new
      2.times do
        subject.on_event(Pikuri::Agent::Event::Tokens.new(
                           input: 1, output: 4, cached: 0, cache_creation: 0,
                           thinking: 3, model_id: 'fake'
                         ))
      end
      subject.on_event(Pikuri::Agent::Event::Assistant.new(content: 'ignored'))

      assert_equal 6, subject.thinking
      assert_equal 8, subject.output
    end

    it 'treats an absent reasoning count as none' do
      subject = described_class.new
      subject.on_event(Pikuri::Agent::Event::Tokens.new(
                         input: 1, output: 4, cached: nil, cache_creation: nil,
                         thinking: nil, model_id: 'fake'
                       ))
      assert_equal 0, subject.thinking
    end
  end
end
