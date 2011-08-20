class ProspectingController < TropoController
  def start
    timeout = custom_params[:timeout].to_i
    message = custom_params[:message]
    voice = custom_params[:voice]

    #Record the session
    create_session_record(username)
    from

    #Generate the outbound message, initiated by the Tropo REST API (see call_user)
    if outbound_call?
      #An outgoing one-off message
      if message
        send_message(t, username, network, channel, get_outbound_number, message, voice)
        store_outgoing_message(network, channel, username, message)
      #A question to be asked - only one say for the first outbound question.
      else
        call_user(t, username, network, channel, timeout, get_outbound_number)
        say_session_message(t)

        #Set up say for ask.
        say = [{:value => custom_params[:text]}]
        say << {:event => 'nomatch', :value => custom_params[:invalid_message]} if custom_params[:invalid_message]

        opts = {:name => custom_params[:ask_id],
                :attempts => custom_params[:attempts].to_i,
                :choices => {:value => custom_params[:choices]},
                :timeout => timeout,
                :say => say}

        #Suppress the footer for administrative questions (e.g. account verification)
        opts.merge!(:suppress_footer => true) if opts[:name] =~ /admin/
        t.ask opts

        #Store outgoing message
        store_outgoing_message(network, channel, username, custom_params[:text])
      end
    #Respond to an initial message from the user
    else
      say_session_message(t)

      #Store incoming message
      store_incoming_message(network, channel, username, input)

      #This this is only necessary if we ask in response to a user's inbound session creation, which for now, we assume.
      throw_away_first_answer if channel == 'TEXT'
    end

    #Only provide events if this is the beginning of an inbound or outbound conversation.
    unless outbound_call? && message
      t.on :event => 'incomplete', :next => record_timeout_url(:network => network, :from => username)
      t.on :event => 'continue', :next => process_answer_url
    end

    render :json => t.response
  end

  def process_answer
    say_session_message(t)

    #Store incoming message
    if tropo_result.actions
      tropo_result.actions.each do |ask_id, data|
        incoming_message = data.value
        store_incoming_message(network, channel, from, incoming_message)

        #Get next thing to do
        next_response = JSON.parse(KoachedContentClient.new(tropo_session_record.entry_point).send_answer(network, from, incoming_message, ask_id))

        #Store outgoing message - figure out how best to do this given that outgoing can be multiple says, etc.
        next_response.each {|item| store_outgoing_item_message(network, channel, from, item)}

        #Handle multiple says in the response.
        if next_response.map {|item| item.has_key?('say') || item.has_key?('ask')}.size > 1
          next_response.each_with_index {|item, i| add_delay_to_say(item) if i > 0}
        end

        #Generate next response
        generate_tropo_response(next_response)
      end
    #This is what happens when it's a voice call and this is the first response.
    elsif tropo_result.state == 'RINGING'
      next_response = JSON.parse(KoachedContentClient.new(tropo_session_record.entry_point).send_answer(network, from, 'answered_phone', 'throwaway'))
      generate_tropo_response(next_response)
    end

    t.on :event => 'incomplete', :next => record_timeout_url(:network => network, :from => from)
    t.on :event => 'continue', :next => process_answer_url

    render :json => t.response
  end

private
  def generate_tropo_response(next_response)
    t.to_hash[:tropo] += next_response
    unless t.to_hash[:tropo].detect {|hsh| hsh.has_key?('ask')}
      t.say('Goodbye', :suppress_footer => true) if channel == 'VOICE'
      t.hangup
    end
  end
end