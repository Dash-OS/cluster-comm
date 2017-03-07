::oo::define ::cluster::cluster {
  variable ID NS SYSTEM_ID SERVICE_ID CONFIG PROTOCOLS HOOKS TAGS AFTER_ID
  variable UPDATED_PROPS CHANNELS QID QUERIES
}

::oo::define ::cluster::cluster constructor { id config } {
  # Strip any periods (.) from the name as they are not allowed.  We do this
  # instead of producing an error.
  namespace path [list ::cluster {*}[namespace path]]
  set ID       $id
  set QUERIES  [dict create]
  set HOOKS    [dict create]
  set TAGS     [dict get $config tags]
  dict unset config tags
  set CONFIG   $config
  set NS       ::cluster::clusters::${ID}
  set AFTER_ID {}
  set CHANNELS [dict create]
  namespace eval $NS {}
  namespace eval ${NS}::services {}
  namespace eval ${NS}::queries  {}
  set UPDATED_PROPS [list tags]
  my BuildSystemID
  my BuildProtocols
  my heartbeat
  my discover
}

# We need to destroy our various objects in the appropriate order so they have
# access to the pieces they may need to clean themselves up.
::oo::define ::cluster::cluster destructor {
  after cancel $AFTER_ID
  if { [namespace exists ${NS}::services] } {
    # Delete the namespace holding all of our services attached to this cluster.
    namespace delete ${NS}::services
  }
  if { [namespace exists ${NS}::protocols] } {
    # Delete the namespace holding all of our protocols
    namespace delete ${NS}::protocols
  }
  if { [namespace exists ${NS}::queries] } {
    # Delete the namespace holding our query objects
    namespace delete ${NS}::queries 
  }
  # Delete our entire namespace
  namespace delete ${NS}
}

# Provide the desired system id which we will include with any packets that
# we encode.
::oo::define ::cluster::cluster method BuildSystemID {} {
  set SYSTEM_ID  [::cluster::hwaddr]
  set SERVICE_ID [shortid]
}

# Build any protocols that our cluster supports.  These will be used to build
# the communication channels with the clients.  We may have a mix of protocols
# supported by a cluster as well.
#
# We expect any supported protocols to be classes defined in the ::cluster::protocol::$protocol
# command space where the protocol will receive [self] $ID $config arguments and should 
# provide capabilities for both sending and receiving using the protocol.
::oo::define ::cluster::cluster method BuildProtocols {} {
  namespace eval ${NS}::protocols {}
  foreach protocol [dict get $CONFIG protocols] {
    if { [info commands ::cluster::protocol::$protocol] ne {} } {
      dict set PROTOCOLS $protocol \
        [::cluster::protocol::$protocol create \
          ${NS}::protocols::$protocol [self] $ID $CONFIG
        ]
    } else {
      # If we do not know the given protocol, raise an error
      throw error "Unknown Cluster Protocol Requested: $protocol"
    }
  }
}

# We send a heartbeat to the cluster at the given interval.  Any listening services
# will reset their timers for our service as they know we still exist.s
::oo::define ::cluster::cluster method heartbeat { {props {}} {tags 0} {channel 0} } {
  try {
    if { $channel == 0 } {
      # We only reset the heartbeat timer when broadcasting our heartbeat
      after cancel $AFTER_ID
      set AFTER_ID [ after [dict get $CONFIG heartbeat] [namespace code [list my heartbeat]] ]
      # Build the payload for the broadcast heartbeat - be sure we broadcast any updated
      # props to the cluster.
      set props [lsort -unique [concat $UPDATED_PROPS $props]]
      set UPDATED_PROPS [list]
      my CheckServices
    }
    if { "tags" in $props } { set tags 1 }
    set payload [my heartbeat_payload $props $tags $channel]
    my broadcast $payload
  } on error {result options} {
    puts "Heartbeat Error: $result"
  }
}

::oo::define ::cluster::cluster method CheckServices {} {
  # Check through each of our services to see if they have expired
  foreach service [my services] {
    try {
      set info [$service info]
      if { [dict exists $info last_seen] } { 
        set lastSeen [expr { [clock seconds] - [dict get $info last_seen] } ]
        if { $lastSeen > [dict get $CONFIG ttl] } { catch { $service destroy } }
      } else { $service destroy }
    } on error {result options} {
      puts "Service Check Error: $result"
      catch { $service destroy }
    }
  }
}

::oo::define ::cluster::cluster method is_local { address } {
  if { $address in [::cluster::local_addresses] } { return 1 } else { return 0 }
}

# Called by any of our supported protocols to parse / handle a received payload
# from a remote/local client.  We will check to make sure the given service passes
# our Security Policies and pass the payload through to our handlers if it does.
::oo::define ::cluster::cluster method receive { proto chanID packet } {
  try {
    # Trim then check to make sure the data is not empty. If it is, cancel evaluation.
    if { [string trim $packet] eq {} } { return }
    
    # Get information about the requester from the protocol
    set descriptor [ $proto descriptor $chanID ]
    
    if { [dict get $CONFIG remote] == 0 } {
      # When we have defined that we only wish to work with local scripts, we will 
      # check and immediately ignore any data received from outside the localhost
      if { ! [dict exists $descriptor local] } {
        if { ! [my is_local [dict get $descriptor address]] } { 
          return 
        } else { dict set descriptor local 1 }
      } else {
        if { ! [dict get $descriptor local] } { return }
      }
    }
    
    # Attempt to decode the received packet.  
    # An empty payload will be returned if we fail to decode the packet for any reason.
    set payload [::cluster::packet::decode $packet [self]]
    if { $payload eq {} || ! [dict exists $payload sid] || [dict get $payload sid] eq $SERVICE_ID } {
      # Ignore empty payloads or payloads that we receive from ourselves.
      return
    }

    # Called before anything is done with the received payload but after it is
    # decoded. $payload may be modified if necessary before it is further evaluated.
    try [my run_hook evaluate receive] on error {r} { return }
    
    try [my run_hook channel receive [dict get $payload channel]] on error {r} { return }
    
    #lassign $payload type rchan op ruid system_id service_id protocols flags data
    
    # Provide the data to the matching service to handle and parse.  Create the
    # service if it does not exist.  
    # - If we receive an empty value in return, the received data has been rejected.
    set service [my service $proto $chanID $payload $descriptor]
    if { $service eq {} } { return }
    
    set protocol [$proto proto]
    if { $protocol ne "c" } {
      my event channel receive $protocol $chanID $service
    }
    
    $service receive $proto $chanID $payload $descriptor
    
  } on error {result options} {
    ::onError $result $options "While Parsing a Received Cluster Packet"
  }
}

# A filter is a list of services which should parse / receive the given payload.
# It is used as an insecure way of routing broadcasted data to specific clients 
# When we have not yet created a channel.  For example, it can be useful to request
# a group of clients to join a specific channel.
::oo::define ::cluster::cluster method check_filter { filter } {
  puts "Checking Filter: $filter"
  if { $SERVICE_ID in $filter } { return 1 }
  if { $SYSTEM_ID in $filter } { return 1 }
  foreach tag $TAGS { if { $tag in $filter } { return 1 } }
  puts "Filter Does Not Match, Ignore Request"
  return 0
}

# Gather the public properties of each protocol that we support.
::oo::define ::cluster::cluster method ProtoProps { {pdict {}} } {
  dict for { protocol ref } $PROTOCOLS {
    set props [$ref props]
    if { $props ne {} } { dict set pdict $protocol $props }
  }
  return $pdict
}

::oo::define ::cluster::cluster method event {ns event proto args} {
  switch -nocase -glob -- $ns {
    cha* - channel {
      my ChannelEvent $event $proto {*}$args
    }
  }
}

::oo::define ::cluster::cluster method ChannelEvent {event proto {chanID {}} args} {
  switch -nocase -glob -- $event {
    o* - opens {
      lassign $args service
      dict set CHANNELS $chanID [dict create \
        proto    $proto \
        created  [clock seconds]
      ]
      if { $service ne {} } { 
        dict set CHANNELS $chanID service $service
        $service event channel open $proto $chanID
      }
    }
    c* - close {
      if { [dict exists $CHANNELS $chanID service] } {
        set service [dict get $CHANNELS $chanID service]
      } else { lassign $args service }
      if { $service ne {} } { $service event channel close $proto $chanID }
      catch { dict unset CHANNELS $chanID }
    }
    r* - receive {
      lassign $args service
      if { $service ne {} } { dict set CHANNELS $chanID service $service }
    }
  }
  return
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
  if { [dict get $CONFIG remote] == 0 && $system_id ne $SYSTEM_ID } { return }
  #lassign $payload type rchan op ruid system_id service_id protocols flags data
  
  set uuid ${service_id}@${system_id}
  
  set service ${NS}::services::$uuid
  
  set serviceExists [expr { [info commands $service] ne {} }]
  
  # Call our service eval hook
  try [my run_hook evaluate service] on error {r} { return }
  
  if { [string is true $serviceExists] } {
    # If our service already exists, we will validate it against the
    # received data to determine if we want to allow communication
    # with the service.  If we validate, then we will return the 
    # reference to the service to our handler.
    try [my run_hook service validate] on error {r} { return }
    
    if { [$service validate $proto $chanID $payload $descriptor] } { return $service }
  } else {
    # If we have never seen this service, we will create it.  We will check
    # it against our security policies and retain it if it is a service we 
    # are allowed to communicate with.  Otherwise it will be destroyed.
    try {
      set service [::cluster::service create $service [self] $proto $chanID $payload $descriptor]
      try [my run_hook service discovered] on error {r} { return }
      return $service
    } on error {r} {
      puts "Service Creation Error: $r"
      # Do nothing on creation error
    }
  }
  return
}

::oo::define ::cluster::cluster method service_lost { service } {
  try [my run_hook service lost] on error {r} { return }
}

# Currently we just save the hooks without validating them as a supported hook.
# protocol hooks are $protocol send/receive
# global hooks are send/receive
::oo::define ::cluster::cluster method hook args {
  set body [lindex $args end]
  set path [lrange $args 0 end-1]
  dict set HOOKS {*}$path $body
}

# When we want to retrieve the body for a given hook, we call this method with
# the desired hook key.  We will either return {} or the given hooks body to be
# evaluated.
::oo::define ::cluster::cluster method run_hook args {
  if { $HOOKS eq {} } { return }
  tailcall try [::cluster::ifhook $HOOKS {*}$args]
}


# Get our scripts UUID to send in payloads
::oo::define ::cluster::cluster method uuid {} { return ${SERVICE_ID}@${SYSTEM_ID} }

# Retrieve how long a service should be cached by the protocol.  If we do not
# hear from a given service for longer than the $ttl value, the service will be 
# removed from our cache.
::oo::define ::cluster::cluster method ttl  {} { return [dict get $CONFIG ttl] }

::oo::define ::cluster::cluster method protocols {} { return [dict get $CONFIG protocols] }

::oo::define ::cluster::cluster method protocol { protocol } {
  if { [dict exists $PROTOCOLS $protocol] } {
    return [dict get $PROTOCOLS $protocol] 
  }
}

::oo::define ::cluster::cluster method props args {
  set props [dict create]
  foreach prop $args {
    if { $prop eq {} } { continue }
    switch -nocase -glob -- $prop {
      protop* - protoprops { set props [my ProtoProps $props] }
    }
  }
  return $props
}

# A list of all the currently known services
::oo::define ::cluster::cluster method services {} {
  return [info commands ${NS}::services::*]
}

::oo::define ::cluster::cluster method known_services {} { llength [my services] }

::oo::define ::cluster::cluster method config { args } {
  return [dict get $CONFIG {*}$args]
}

::oo::define ::cluster::cluster method flags {} { 
  return [ list [my known_services] 0 0 0 ] 
}

::oo::define ::cluster::cluster method type { type } {
  if { ! [string is entier -strict $type] } {
    switch -nocase -glob -- $type {
      discon* - close { set type 0 }
      bea* - heart*   { set type 1 }
      discov* - find  { set type 2 }
      req* - com*     { set type 3 }
      q*              { set type 4 }
      res* - answ*    { set type 5 }
      event           { set type 6 }
      default { throw error "Unknown Type: $type" }
    } 
  }
  return $type
}

::oo::define ::cluster::cluster method channel { channel } {
  if { ! [string is entier -strict $channel] } {
    switch -nocase -glob -- $channel {
      broadcast - br* { set type 0 }
      system    - sy* { set type 1 }
      lan - lo* - la* { set type 2 }
      default { throw error "Unknown Channel: $channel" }
    }
  }
  return $channel
}

# Send a discovery probe to the cluster.  Each service will send its response
# based on the best protocol it can find. 
::oo::define ::cluster::cluster method discover { {ruid {}} {channel 0} } {
  my variable LAST_DISCOVERY
  if { ! [info exists LAST_DISCOVERY] } { set LAST_DISCOVERY [clock seconds] } else {
    set now [clock seconds]
    if { ( $now - $LAST_DISCOVERY ) <= 30 } {
      # We do not allow discovery more than once for every 30 seconds.
      return 0
    } else { set LAST_DISCOVERY $now }
  }
  return [ my broadcast [ my discovery_payload [list protoprops] 1 $channel ] ]
}

# Broadcast to the cluster.  This is a shortcut to send to the cluster protocol.
::oo::define ::cluster::cluster method broadcast { payload } {
  set proto [dict get $PROTOCOLS c] 
  try [my run_hook broadcast] on error {r} { return 0 }
  return [ $proto send [::cluster::packet::encode $payload] ]
}

::oo::define ::cluster::cluster method query { args } {
  if { [dict exists $args -id] } {
    set qid [dict get $args -id] 
  } else { 
    set qid [my QueryID] 
    dict set args -id $qid
  }
  
  set query ${NS}::queries::$qid
  if { [info commands $query] ne {} } {
    # When we have a query which matches a previously created query
    # that has not yet timed out we will force it to finish first.
    $query destroy
  }
  
  try {
    set query [::cluster::query create $query [self] {*}$args]
  } trap NO_SERVICES {result} {
    return
  } on error {result options} {
    puts "QUERY CREATION ERROR: $result"
    return
  }
  
  dict set QUERIES $qid $query
  
  return $query
}

::oo::define ::cluster::cluster method QueryID {} {
  return [format {q%s%s#%s} \
    [string index $SERVICE_ID 0] \
    [string index $SERVICE_ID 2] \
    [string index $SERVICE_ID end] \
    [::cluster::query_id]
  ]
}

# Called by a service when it wants to provide a response to a query object.
::oo::define ::cluster::cluster method query_response { service payload } {
  if { [dict exists $payload ruid] } {
    set ruid [dict get $payload ruid]
    if { [dict exists $QUERIES $ruid] && [info commands [dict get $QUERIES $ruid]] ne {} } {
      try {
        return [ [dict get $QUERIES $ruid] event response $service $payload ] 
      } on error {result} {
        puts "QUERY REQUEST ERROR: $result"
        return 0
      }
    } else { return 0 }
  } else { return 0 }
}

::oo::define ::cluster::cluster method query_done { qid } {
  if { [dict exists $QUERIES $qid] } { dict unset QUERIES $qid }
}

# Send a payload to the given service(s).  Optionally provide a list of protocols
# which we want to send to if possible.  This will be matched against each services
# protocols to determine the best method of communication to utilize.
::oo::define ::cluster::cluster method send { services payload {protocols {}} args } {
  set sent   [list]
  set failed [list]
  foreach service $services {
    set rservices [my resolve $service]
    foreach resolved $rservices {
      if { $resolved in $sent || $resolved in $failed } { continue }
      try { 
        set protocol [ $resolved send $payload $protocols ]
        if { $protocol ne {} } {
          lappend sent $resolved
        } else {
          if { $resolved ni $failed } { lappend failed $resolved }
        }
      } on error {result} {
        puts "Failed to Send to Service $service | $result  \n Payload: $payload"
      }
    }
  }
  return [list $sent $failed]
}

# Resolve services by running a search against each $arg to return the 
# filtered services which match every arg. Resolution is a simple "tag-based"
# search which matches against a services given tags.  By default a service will
# resolve with:
#   $ip       - The IP of the Service
#   $name     - The name of the Service
#   $tags     - Any of the tags defined by the service
#   localhost - If the service is local it will resolve with "localhost"
# set services [$cluster resolve localhost my_service]
::oo::define ::cluster::cluster method resolve args {
  set services [my services]
  foreach filter $args {
    if { $services eq {} } { break }
    set services [lmap e $services { 
      if { [string match "::*" $filter] || [string is true -strict [ $e resolve $filter ]] } {
        set e
      } else { continue }
    }]
  }
  return $services
}

# Tags are sent to clients to give them an idea for what each service provides or
# wants other services to be aware of.  Tags are sent only when changed or when requested.
::oo::define ::cluster::cluster method tags { {action {}} args } {
  if { $action eq {} } { return $TAGS }
  set prev_tags $TAGS
  if { [string equal [string index $action 0] -] } {
    set action [string trimleft $action -]
  } else {
    set args [list $action {*}$args]
    set action {}
  }
  if { $args ne {} } {
    switch -- $action {
      append { lappend TAGS {*}$args }
      remove { 
        foreach tag $TAGS {
          set TAGS [lsearch -all -inline -not -exact $TAGS $tag]
        }
      }
      replace - default { set TAGS $args }
    }
  }
  try [my run_hook tags update] on error {r} {
    # If we receive an error during the hook, we will revert to the previous tags
    set TAGS $prev_tags
  }
  if { $prev_tags ne $TAGS } {
    # If our tags change, our change hook will fire
    set UPDATED_PROPS [concat $UPDATED_PROPS [list tags]]
    try [my run_hook tags changed] on error {r} {
      # We don't do anything if this produces error, use update for that.  This
      # should be used when a tag update is accepted, for example if we wanted to
      # then broadcast to the cluster with our updated tags.
    }
  }
  return $TAGS
}

