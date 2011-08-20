VOICE = 'vanessa'
DEFAULT_OPTIONS = {:attempts    => 2,
                   :timeout     => 15,
                   :voice       => VOICE,
                   :choices     => '1, 2, 3',
                   :onBadChoice => lambda {|event|
                                         case event.attempt
                                           when 1
                                             say "Bad choice, please try again", {:voice => VOICE}
                                           when 2
                                             say "Dude, really, it's 1, 2, or 3", {:voice => VOICE}
                                             hangup
                                         end
                                       }}

result = ask 'Welcome to Demo 3! Press 1 for conference, 2 for transfer, 3 for cool audio', DEFAULT_OPTIONS
if result.name == 'choice'
  case result.value
    when '1'
      say "Welcome to the demo conference"
      conference "hcc_demo_conference", {:terminator => "*",
                                         :playTones => true,
                                         :onChoice => lambda {|event| say("Disconnecting")}}
      say "Thanks for using the demo conference"
    when '2'
      target_phone_number = "2817482498"
      say "About to transfer this call to #{target_phone_number}"
      transfer "+1#{target_phone_number}"
    when '3'
      say "I'm going to play some They Might Be Giants now"
      say "http://hosting.tropo.com/90387/www/audio/xmliveShadowGovt.mp3"
  end
end

hangup


