# This example shows the (t) (TCP) protocol handler for the cluster-comm package.
# A protocol is a class which provides a translation of a protocol so that we can
# communicate successfully with it with cluster-comm. 
#
# A protocol must generally define both a SERVER and a CLIENT handler.  For our 
# server, we expect to listen to connections from clients and pass them to our
# cluster so it can be properly handled.
if { [info commands ::cluster::protocol::t] eq {} } {
  ::oo::class create ::cluster::protocol::t {}
}

::oo::define ::cluster::protocol::t {
  variable SOCKET PORT CLUSTER ID
}

::oo::define ::cluster::protocol::t constructor { cluster id config } {
  set ID $id
  set CLUSTER  $cluster
  my CreateServer
}

::oo::define ::cluster::protocol::t destructor {
  catch { my CloseSocket $SOCKET }
}

## Expected Accessors which every protocol must have.
::oo::define ::cluster::protocol::t method proto {} { return t }

# The props that are required to successfully negotiate with the protocol.
::oo::define ::cluster::protocol::t method props {} { 
  return [dict create \
    port $PORT
  ]
}

::oo::define ::cluster::protocol::t method CreateServer {} {
  set SOCKET [socket -server [namespace code [list my Connect]] 0]
  set PORT   [lindex [chan configure $SOCKET -sockname] end]
} 

::oo::define ::cluster::protocol::t method Connect { chanID address port {service {}} } {
  chan configure $chanID -blocking 0 -translation binary -buffering none
  chan event $chanID readable [namespace code [list my Receive $chanID]]
  $CLUSTER event channel open [self] $chanID $service
}

::oo::define ::cluster::protocol::t method Receive { chanID } {
  try {
    if { [chan eof $chanID] } { my CloseSocket $chanID } else {
      $CLUSTER receive [self] $chanID [read $chanID]
    }
  } on error {result options} {
    puts "TCP RECEIVE ERROR: $result"
  }
}

::oo::define ::cluster::protocol::t method CloseSocket { chanID {service {}} } {
  catch { chan close $chanID }
  $CLUSTER event channel close [self] $chanID $service
}

::oo::define ::cluster::protocol::t method OpenSocket { service } {
  set props [$service proto_props t]
  if { $props eq {} } { throw error "Services TCP Protocol Props are Unknown" }
  if { ! [dict exists $props port] } { throw error "Unknown TCP Port for $service" }
  set address [$service ip]
  set port    [dict get $props port]
  set sock    [socket $address $port]
  my Connect $sock $address $port $service
  return $sock
}

# When we want to send data to this protocol we will call this with the
# service that we are wanting to send the payload to. We should return 
# 1 or 0 to indicate success of failure.
::oo::define ::cluster::protocol::t method send { packet {service {}} } {
  try {
    # Get the props and data required from the service
    if { $service eq {} } { throw error "No Service Provided to TCP Protocol" }
    # First check if we have an open socket and see if we can use that. If
    # we can, continue - otherwise open a new connection to the client.
    set sock [$service socket t]
    if { $sock ne {} } {
      try {
        puts -nonewline $sock $packet
      } on error {result options} {
        my CloseSocket $sock $service
        set sock {}
      }
    }
    if { $sock eq {} } {
      set sock [my OpenSocket $service]
      puts -nonewline $sock $packet
    }
    return 1
  } on error {result options} {
    puts "Failed to Send to TCP Protocol: $result"
    puts $options
  }
  return 0
}

# Called by our service when we have finished parsing the received data. It includes
# information as-to how the completed data should be parsed.
# Cluster ignores any close requests due to no keep alive.
::oo::define ::cluster::protocol::t method done { service chanID keepalive {response {}} } {
  if { [string is false $keepalive] } { my CloseSocket $chanID $service }
}

::oo::define ::cluster::protocol::t method descriptor { chanID } {
  lassign [chan configure $chanID -peername] address hostname port
  return [ dict create \
    address  $address  \
    hostname $hostname \
    port     $port
  ]
}
