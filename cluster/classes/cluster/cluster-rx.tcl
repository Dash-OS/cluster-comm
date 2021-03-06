# Called by any of our supported protocols to parse / handle a received payload
# from a remote/local client.  We will check to make sure the given service passes
# our Security Policies and pass the payload through to our handlers if it does.
#
# NOTE: As of version >1.1.4 packets are processed by our bpacket streams so we know
#       that any packets we might receive at this point will be complete packets.
::oo::define ::cluster::cluster method receive { protocol chanID packet } {
  try {
    # Get information about the requester from the protocol
    set proto      [my protocol $protocol]
    set descriptor [$proto descriptor $chanID]

    if { [string is false -strict [dict get $CONFIG remote]] } {
      # When we have defined that we only wish to work with local scripts, we will
      # check and immediately ignore any data received from outside the localhost
      if { ! [dict exists $descriptor local] } {
        if { ! [my is_local [dict get $descriptor address]] } {
          puts "Received from Non Local Source: $descriptor"
          # puts [::cluster::packet::decode $packet [self]]
          return
        } else {
          dict set descriptor local 1
        }
      } else {
        if { ! [dict get $descriptor local] } {
          puts "Received from Non Local Source: $descriptor"
          # puts [::cluster::packet::decode $packet [self]]
          return
        }
      }
    }

    # our stream handler should insure we receive single packets at a time here.
    set payload [::cluster::packet::decode $packet [self]]

    if {$payload eq {}} {
      # if a packet was ignored or could not be decoded it will be empty
      # generally this is due to -validate causing it to return.
      #
      # this can be expected if we receive a packet from ourselves or
      # via a filter which doesnt match.
      return
    }

    # Are we currently listening to the channel that the communication was
    # received on?
    if {[dict get $payload channel] ni $COMM_CHANNELS} {
      # TODO: Handle this with logger
      puts stderr "Not In Received Channel [dict get $payload channel] "
      return
    }

    # Called before anything is done with the received payload but after it is
    # decoded. $payload may be modified if necessary before it is further evaluated.
    try {my run_hook evaluate receive} on error {r} { return }

    try {my run_hook channel [dict get $payload channel] receive} on error {r} { return }

    #lassign $payload type rchan op ruid system_id service_id protocols flags data

    # Provide the data to the matching service to handle and parse.  Create the
    # service if it does not exist.
    # - If we receive an empty value in return, the received data has been rejected.
    set service [my service $proto $chanID $payload $descriptor]
    if {$service eq {}} { return }
    set protocol [$proto proto]

    if { $protocol ne "c" } {
      my event channel receive $proto $chanID $service
    }

    incr payloads_remaining -1
    $service receive $proto $chanID $payload $descriptor $payloads_remaining
  } on error {result options} {
    #puts $result
    ::onError $result $options "While Parsing a Received Cluster Packet" $proto $chanID
  }
}

# A filter is a list of services which should parse / receive the given payload.
# It is used as an insecure way of routing broadcasted data to specific clients
# When we have not yet created a channel.  For example, it can be useful to request
# a group of clients to join a specific channel.
::oo::define ::cluster::cluster method check_filter { filter } {
  if {$SERVICE_ID in $filter} {
    return true
  }
  if {$SYSTEM_ID in $filter} {
    return true
  }
  # filter is a list of values - we need to check if any of our tags
  # match a given filter.
  foreach tag $TAGS {
    if { $tag in $filter } {
      return true
    }
  }
  return false
}

# Whenever we receive data, we will check to see if the service already exists
# within our cache.  If it does, we will return a reference to the service.  If
# it doesn't, we will create it then return its reference.
#
# If a service should not be allowed to communicate with us, we will return an
# empty string at which point the command should cease to parse the received
# payload immediately.
::oo::define ::cluster::cluster method service { proto chanID payload descriptor } {
  set system_id  [dict get $payload hid]
  set service_id [dict get $payload sid]

  # Added Security - if the system id does not match, we dont parse it when only
  # accepting local.
  if {[dict get $CONFIG remote] == 0 && $system_id ne [my hid]} {
    # TODO: Handle this situation with event logging system
    return
  }

  set uuid ${service_id}@${system_id}

  set service ${NS}::services::$uuid

  set serviceExists [expr {[info commands $service] ne {}}]

  # Call our service eval hook
  try {my run_hook evaluate service} on error {r} { return }

  if { [string is true $serviceExists] } {
    # If our service already exists, we will validate it against the
    # received data to determine if we want to allow communication
    # with the service.  If we validate, then we will return the
    # reference to the service to our handler.
    try {my run_hook service validate} on error {r} { return }
    if {[$service validate $proto $chanID $payload $descriptor]} {
      return $service
    }
  } else {
    # If we have never seen this service, we will create it.  We will check
    # it against our security policies and retain it if it is a service we
    # are allowed to communicate with.  Otherwise it will be destroyed.
    try {
      set service [::cluster::service create $service [self] $proto $chanID $payload $descriptor]
      return $service
    } on error {r o} {
      catch { ::onError $r $o "While Creating a Cluster Service" $service }
      # Do nothing on creation error
    }
  }
  return
}
