# Does a Faraday adapter's #call span the whole SSE stream, or return early?
# If it spans it, a semaphore acquired around `super` throttles streaming correctly.
require 'pikuri-core'
require 'faraday'
require 'json'

T0 = Time.now
def stamp = format('%6.2fs', Time.now - T0)

MARKS = []

class TimingAdapter < Faraday::Adapter::NetHttp
  EXTRA = { 'chat_template_kwargs' => { 'enable_thinking' => false } }.freeze

  def call(env)
    if env.body.is_a?(String) && env.url.path.to_s.end_with?('/chat/completions')
      env.body = JSON.generate(JSON.parse(env.body).merge(EXTRA))
    end
    MARKS << [:adapter_enter, Time.now]
    super
  ensure
    MARKS << [:adapter_exit, Time.now]
  end
end

# Records when deltas actually reach the listener stack.
class DeltaClock < Pikuri::Agent::Listener::Base
  def on_event(event)
    MARKS << [:"event_#{event.class.name.split('::').last}", Time.now]
  end
end

transport = Pikuri::Agent::ChatTransport.from_openai_server(
  server: 'http://mavi-fw:8080',
  model: 'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M',
  context_window: 65_536 # explicit -> no /props probe, per agent.rb:706
).with(faraday_adapter: TimingAdapter)

agent = Pikuri::Agent.new(
  transport: transport,
  system_prompt: 'You follow instructions exactly.',
  step_limit: Pikuri::Agent::Control::StepLimit.new(max: 1),
  streaming: true
) { |c| c.add_listener DeltaClock.new }

MARKS << [:run_loop_enter, Time.now]
agent.run_loop(user_message: 'List the integers from 1 to 150, one per line, nothing else.')
MARKS << [:run_loop_exit, Time.now]
agent.close

# Report: adapter window vs where the deltas landed.
enter = MARKS.find { |k, _| k == :adapter_enter }[1]
exit_ = MARKS.find { |k, _| k == :adapter_exit }[1]
deltas = MARKS.select { |k, _| k.to_s.include?('Delta') }.map(&:last)

puts "adapter #call spanned : #{(exit_ - enter).round(2)}s"
puts "run_loop total        : #{(MARKS.last[1] - MARKS.first[1]).round(2)}s"
puts "delta events          : #{deltas.size}"
if deltas.any?
  puts "first delta           : #{(deltas.first - enter).round(2)}s after adapter entered"
  puts "last delta            : #{(deltas.last - enter).round(2)}s after adapter entered"
  inside = deltas.count { |t| t >= enter && t <= exit_ }
  puts "deltas INSIDE the adapter window: #{inside}/#{deltas.size}"
end
puts "\nordered marks (deduped):"
seen = Hash.new(0)
MARKS.each do |k, t|
  seen[k] += 1
  next if k.to_s.include?('Delta') && seen[k] > 2 && seen[k] < deltas.size

  puts format('  %-28s %s', k, format('%6.2fs', t - T0))
end
