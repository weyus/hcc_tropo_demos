DEFAULT_OPTIONS = {:attempts    => 2,
                   :timeout     => 15,
                   :voice       => 'vanessa',
                   :choices     => [1, 2, 3],
                   :onBadChoice => lambda {|event|
                                         case event.attempt
                                           when 1
                                             say "Bad choice, please try again", { :voice => VOICE }
                                           when 2
                                             say "Dude, really, it's 1, 2, or 3'", { :voice => VOICE }
                                             hangup
                                         end
                                       }}

result = ask 'Press 1 for conference, 2 for transfer, 3 for cool audio', DEFAULT_OPTIONS
if result.name == 'choice'
  case result.value
    when '1'
      say "Conference"
    when '2'
      say "Transfer"
    when '3'
      say "Audio"
  end
end

hangup


