require 'rest-client'
require 'tropo-webapi-ruby'

class TropoController < ApplicationController
  include TropoHelper

  SHOW_SESSION_IDS = false
  COMMANDS = {'DONE' => 'to end this session with Koached',
              ['HELP', '?'] => 'for help'}
  OUTBOUND_CALL_PAUSE_SECONDS = 1
  MULTI_SAY_PAUSE = '2s'

  @@configuration = YAML.load_file("#{::Rails.root.to_s}/config/tropo.yml")

  before_filter :kill_session, :except => [:kill_sessions, :allow_sessions]
  before_filter :parse_response, :except => [:kill_sessions, :allow_sessions]
  before_filter :identify_network, :except => [:debug, :kill_sessions, :allow_sessions, :hangup]
  before_filter :handle_system_commands, :except => [:debug, :kill_sessions, :allow_sessions, :hangup]
#  before_filter :handle_bad_response, :except => [:debug, :kill_sessions, :allow_sessions, :hangup]
  after_filter :debug_response, :except => [:debug, :kill_sessions, :allow_sessions]

  cattr_accessor :kill_flag, :configuration, :timeout
  attr_reader :t, :tropo_response

  #Strictly for verifying that Tropo IM API is working.
  #Notice the use of a standard Tropo::Generator instead of a Koached specific one.
  def debug
    debug_t = Tropo::Generator.new

    if outbound_call?
      network = custom_params[:network] || (initial_text ? 'SMS' : 'SIP')
      username = custom_params[:username] || '18328654766'

      outbound_number = ['SMS', 'SIP'].include?(network) ? TropoController.configuration['outbound_numbers'][ENV['RAILS_ENV']].to_s : nil
      call_user(debug_t, username, network, network == 'SIP' ? 'VOICE' : 'TEXT', 120, outbound_number)

      say_session_message(debug_t)
      debug_t.say(custom_params[:message] || "I called you.")

#      say = [{:value => "We are contacting you.  Say some numbers."}]
#      opts = {:name => "welcome",
#              :choices => {:value => '[DIGITS]'},
#              :timeout => 120,
#              :say => say}
#      debug_t.ask opts
    else
      say_session_message(debug_t)
      #debug_t.say "Hello there, #{tropo_session.from.id}!"
      nomatch_msg = "Respond with 'YES' or 'NO'"
      say = [{:value => "Thank you for contacting KOACHED. We don't recognize this number, are you here to learn about what we do?"}]
      #say << {:value => nomatch_msg, :event => 'nomatch'}

      opts = {:name => "invitation",
              :attempts => 3,
              :choices => {:value => 'YES, NO'},
              :timeout => 10,
              :say => say}

      debug_t.ask opts
    end
    debug_t.on :event => 'continue', :next => hangup_url
    debug_t.on :event => 'incomplete', :next => hangup_url

    debug_response(debug_t.response)
    render :json => debug_t.response
  end

  def kill_sessions
    @@kill_flag = true
    render :nothing => true
  end

  def allow_sessions
    @@kill_flag = false
    render :nothing => true
  end

  def record_timeout
    KoachedContentClient.new(tropo_session_record.entry_point).send_answer(params[:network], params[:from], 'TIMEOUT', tropo_result.actions.keys.first)
    t.hangup
    render :json => t.response
  end

  def hangup
    t.say('Goodbye.', :suppress_footer => true) unless params[:silent]
    t.hangup
    render :json => t.response
  end

protected
  def input(ask_id = nil)
    value = nil

    if ask_id && tropo_result && tropo_result.actions.respond_to?(ask_id)
      value = tropo_result.actions.send(ask_id).value
    elsif tropo_session
      value = tropo_session.initial_text
    end

    value ? value.strip : nil
  end

  def say_session_message(generator)
    generator.say("Session id: #{session_id}", :suppress_footer => true) if TropoController::SHOW_SESSION_IDS
  end

  def session_id
    if tropo_result
      tropo_result.session_id
    elsif tropo_session
      tropo_session.id
    end
  end

  def create_session_record(username)
    if (! TropoSession.find_by_session_id(session_id)) && (tropo_session.respond_to?(:to) || custom_params[:action] == 'create')
      entry_point = tropo_session.respond_to?(:to) ? tropo_session.to.id : custom_params['outbound_number']
      TropoSession.create(:session_id => session_id,
                          :network => network,
                          :channel => channel,
                          :username => username.sub(/^\+/, ''),
                          :entry_point => entry_point)
    end
  end

  def remove_session_record
    TropoSession.delete_all(['session_id = ?', session_id])
  end

  def custom_params
    tropo_session.respond_to?(:parameters) ? tropo_session.parameters : {}
  end

  def network
    unless @network
      if tropo_session_record
        @network = tropo_session_record.network
      elsif custom_params[:network]
        @network = custom_params[:network]
      #Note that "from" here is the data structure, not the method above.
      elsif tropo_session.respond_to?(:from) && tropo_session.from.respond_to?(:network)
        @network = tropo_session.from.network
      end
    end

    @network
  end

  def channel
    unless @channel
      if tropo_session_record
        @channel = tropo_session_record.channel
      elsif custom_params[:channel]
        @channel = custom_params[:channel]
      #Note that "from" here is the data structure, not the method above.
      elsif tropo_session.respond_to?(:from) && tropo_session.from.respond_to?(:channel)
        @channel = tropo_session.from.channel
      end
    end

    @channel
  end

  def username
    @username = custom_params[:username] || from unless @username
    @username
  end

  def from
    unless @from
      if tropo_session && tropo_session.respond_to?(:from)
        @from = tropo_session.from.id
      elsif tropo_result
        @from = TropoSession.find_by_session_id(tropo_result.session_id).username
      end
    end

    @from
  end

  def to(outbound_username, channel)
    to = "+#{outbound_username.gsub(/[\s+]/, '')}"
    to << ";postd=#{'p' * OUTBOUND_CALL_PAUSE_SECONDS}" if channel == 'VOICE'
    to
  end

  def outbound_call?
    tropo_session && custom_params.respond_to?(:action) && custom_params.action == 'create'
  end

  def call_user(generator, username, network, channel, timeout, from = nil)
    opts = {:to => to(username, channel),
            :channel => channel,
            :network => network,
            :name => 'welcome',
            :timeout => timeout}
    opts.merge!(:from => from) if from
    generator.call opts
  end

  def send_message(generator, username, network, channel, from = nil, message = 'This is a test message', voice = nil)
    opts = {:to => to(username, channel),
            :channel => channel,
            :network => network,
            :say => [{:value => message}],
            :voice => voice,
            :suppress_footer => true}
    opts.merge!(:from => from) if from
    generator.message opts
  end

  def initial_text
    tropo_session && tropo_session.respond_to?(:initial_text) ? tropo_session.initial_text : nil
  end

  def get_outbound_number
    ['SMS', 'SIP'].include?(network) ? custom_params[:outbound_number] : nil
  end

  def store_outgoing_message(network, channel, to, message)
    store_message(network, channel, 'koached', to, message)
  end

  def store_outgoing_item_message(network, channel, to, item)
    if item['ask']
      store_outgoing_message(network, channel, to, item['ask']['say'].detect {|val_hsh| val_hsh.keys == ['value']}['value'])
    elsif item['say']
      store_outgoing_message(network, channel, to, item['say']['value'])
    end
  end

  def store_incoming_message(network, channel, from, message)
    store_message(network, channel, from, 'koached', message)
  end

  #NOT USED.
  def initiate_outbound_call
    token = params[:debug] ? TropoController.configuration['tokens']['debug'] : TropoController.configuration['tokens'][ENV['RAILS_ENV']]

    params_to_pass = {:action => 'create', :token => token}

    [:username, :network, :name, :text, :attempts, :choices, :invalid_message].each do |p|
      params_to_pass[p] = params[p]
    end

    resp = RestClient.get TropoController.configuration['tropo_session_url'], {:params => params_to_pass}
    if resp.code == 200
      logger.debug("Successfully initiated outbound call to #{params[:username]} on #{params[:network]} network")
    else
      logger.debug("Problem initiating outbound call to #{params[:username]} on #{params[:network]} network")
    end

    render :nothing => true
  end

  def throw_away_first_answer
    t.ask :name => 'throwaway',
          :choices => {:value => '[ANY]'},
          :say => [{:value => ''}],
          :suppress_footer => true
  end

  def add_delay_to_say(item)
    if item.has_key?('say')
      item['say']['value'] = "<speak><break time='#{MULTI_SAY_PAUSE}'/>#{item['say']['value']}</speak>"
    elsif item.has_key?('ask')
      item['ask']['say'][0]['value'] = "<speak><break time='#{MULTI_SAY_PAUSE}'/>#{item['ask']['say'][0]['value']}</speak>"
    end
  end

private
  def initialize
    KoachedTropoGenerator.allow_footer = false  #We can change this when we start doing voice.
    @t = KoachedTropoGenerator.new
    @t.footer = "(Enter '?' or 'HELP' for help)"
  end

  def tropo_session
    tropo_response.respond_to?(:session) ? tropo_response.session : nil
  end

  def tropo_result
    tropo_response.respond_to?(:result) ? tropo_response.result : nil
  end

  def kill_session
    if @@kill_flag
      t.hangup
      remove_session_record
      return render :json => t.response
    end

    true
  end

  def help
    #t.say help_text, :suppress_footer => true
    #t.ask
  end

  def end_call
    t.say 'Thanks for using Koached!  Talk to you soon!', :suppress_footer => true
    t.hangup
    remove_session_record
  end

  def handle_system_commands
    if input && (COMMANDS.detect {|k, v| k =~ /^#{Regexp.escape(input)}$/i ||
                                         (k.is_a?(Array) && k.detect {|k2| k2 =~ /^#{Regexp.escape(input)}$/i})})
      case input
        when /^done$/i
          return end_call
        when /^help$/i, '?'
          help
      end

      t.on :event => 'continue', :next => request.referrer

      return render :json => t.response
    end

    true
  end

  def identify_network
    t.network = network
  end

  #This would be a general way to handle responses across the board, outside of the purview of individual Tropo asks.
  def handle_bad_response
    unless good_response?(input)
      t.say "I'm sorry, but I didn't understand your response.#{nl(network)}#{valid_response}#{nl(network)}Please try again#{nl(network)}#{nl(network)}#{help_text}"
      t.on :event => 'continue', :next => request.referrer
      return render :json => t.response
    end

    true
  end

  def parse_response
    @tropo_response = t.parse(params)
  end

  def debug_response(response = t.response)
    logger.info("Response is: #{response}")
  end

  def help_text
    str = "KOACHED COMMANDS#{nl(network)}#{nl(network)}Please type:#{nl(network)}"

    COMMANDS.each do |c, txt|
      if c.is_a?(String)
        str << "#{c} #{txt}#{nl(network)}"
      elsif c.is_a?(Array)
        c.each {|sub_c| str << "#{sub_c} #{txt}#{nl(network)}"}
      end
    end

    str
  end

  def tropo_session_record
    TropoSession.find_by_session_id(session_id)
  end

  def store_message(network, channel, from, to, message)
    tropo_session_record.tropo_messages.create(:network => network,
                                               :channel => channel,
                                               :from => from.sub(/^\+/, ''),
                                               :to => to.sub(/^\+/, ''),
                                               :message => message) if tropo_session_record

  end

  #This sets a global timeout value for all interactions with the Tropo bot.
  #Use DEFAULT_TIMEOUT just in case.
  #NOT USED.
  def self.set_timeout_value(new_timeout = nil)
    if new_timeout
      Cache.set('timeout', new_timeout)
    elsif (! Cache.get('timeout'))
      Cache.set('timeout', TropoQuestion::DEFAULT_TIMEOUT)
    end
  end

  #NOT USED
  def get_sequence_value
    tropo_result.sequence
  end
end