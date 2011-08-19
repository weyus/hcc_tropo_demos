class KoachedTropoGenerator < Tropo::Generator
  include TropoHelper

  cattr_accessor :allow_footer

  attr_accessor :footer, :network

  def ask(params = {}, &block)
    add_footer_to_say(params)

    #Add timestamp to ask_id if it isn't there
    params[:name] << "_#{Time.now.to_f}" unless params[:name] =~ /\.(\d)+$/

    #params.merge!({:allowSignals => "exit", :onSignal => lambda {|event| puts "Got #{event} event!"}})
    super
  end

  def message(params = {}, &block)
    add_footer_to_say(params)
    super
  end

  def on(params = {}, &block)
    add_footer_to_say(params)
    super
  end

  #Add footer to everything that is said, unless, of course, we don't want that.
  def say(value = nil, params = {})
    add_footer(value, params)
    #params.merge!(:allowSignals => "exit", :onSignal => lambda {|event| puts "Got #{event} event!"})
    super
  end

private
  def add_footer(str, params)
    if str && allow_footer && (! params[:suppress_footer])
      str << "#{nl(network)}#{nl(network)}#{footer}"
    end
    params.delete(:suppress_footer)  #Just in case Tropo can't deal with this
  end

  def add_footer_to_say(params)
    params[:say].each {|hsh| add_footer(hsh[:value], params) if hsh[:value] && (hsh[:event] != 'nomatch')} if params[:say]
  end
end