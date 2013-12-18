#!/usr/bin/perl

use v5.14;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Proc::Daemon; # libproc-daemon-perl
use JSON; # libjson-perl
use Config::JSON; # libconfig-json-perl
use HTTP::Tiny;
use Log::Log4perl;
use File::Path qw(make_path);
use feature qw(switch);
use Getopt::Long;
use Data::Dumper;

my $DEBUG  = 0;
my $DAEMON = 1;

my $getopts_rc = GetOptions(
    "debug!"        => \$DEBUG,
    "daemon!"       => \$DAEMON,

    "help|?"        => \&print_usage,
);

# setup signal handlers and daemon stuff
$SIG{INT}  = \&sig_exit;
$SIG{TERM} = \&sig_exit;
$SIG{PIPE} = \&sig_pipe;
$SIG{CHLD} = 'IGNORE';
$SIG{USR1} = \&get_config;
$SIG{USR2} = \&post_config;

our $daemon = Proc::Daemon->new(
  work_dir => "$Bin/../",
);

our $daemons;
if ( $DAEMON ) {
  $daemon->Init();
}

# EventStremr Modules
use EventStreamr::Devices;
our $devices = EventStreamr::Devices->new();
use EventStreamr::Utils;
our $utils = EventStreamr::Utils->new();

# Load Local Config
my $localconfig = Config::JSON->new("$Bin/../settings.json");
$localconfig = $localconfig->{config};

# Station Config
our $stationconfig = Config::JSON->new("$Bin/../station.json");

# Commands
my $commands = Config::JSON->new("$Bin/../commands.json");

# Own data 
our $self;
$self->{config} = $stationconfig->{config};
$self->{config}{macaddress} = getmac();
$self->{devices} = $devices->all();
$self->{commands} = $commands->{config};
$self->{dvswitch}{check} = 1; # check until dvswitch is found
$self->{dvswitch}{running} = 0;
$self->{settings} = $localconfig;
if ($self->{config}{run} == 2) {$self->{config}{run} = 1;}

# Logging
unless ( $DEBUG ) {
  $self->{loglevel} = 'INFO, LOG1' ;
} else {
  $self->{loglevel} = 'DEBUG, LOG1, SCREEN' ;
}

my $log_conf = qq(
  log4perl.rootLogger              = $self->{loglevel}
  log4perl.appender.SCREEN         = Log::Log4perl::Appender::Screen
  log4perl.appender.SCREEN.stderr  = 0
  log4perl.appender.SCREEN.layout  = Log::Log4perl::Layout::PatternLayout
  log4perl.appender.SCREEN.layout.ConversionPattern = %m %n
  log4perl.appender.LOG1           = Log::Log4perl::Appender::File
  log4perl.appender.LOG1.utf8      = 1
  log4perl.appender.LOG1.filename  = $localconfig->{'logpath'} 
  log4perl.appender.LOG1.mode      = append
  log4perl.appender.LOG1.layout    = Log::Log4perl::Layout::PatternLayout
  log4perl.appender.LOG1.layout.ConversionPattern = %d %p %m %n
);

Log::Log4perl::init(\$log_conf);
our $logger = Log::Log4perl->get_logger();
$logger->info("manager starting: pid=$$, station_id=$self->{config}->{macaddress}");

$daemons->{main}{run} = 1;

# HTTP
our $http = HTTP::Tiny->new(timeout => 15);

# Start the API
api();

# Register with controller
$logger->info("Registering with controller $localconfig->{controller}/$self->{config}{macaddress}");
my $response =  $http->post("$localconfig->{controller}/$self->{config}{macaddress}");

# Controller responds with created 201, now we can ask for a blank config
if ($response->{status} == 201) {
  $logger->info("Getting config $localconfig->{controller}/$self->{config}{macaddress}");
  $response =  $http->get("$localconfig->{controller}/$self->{config}{macaddress}");
}


if ($response->{status} == 200 ) {
  my $content = from_json($response->{content});
  $logger->debug({filter => \&Data::Dumper::Dumper,
                  value  => $content}) if ($logger->is_debug());

  if (defined $content) {
    $self->{config} = $content;
    write_config();
  }

  # Run all connected devices - need to get devices to return an array
  if ($self->{config}{devices} eq 'all') {
    $self->{config}{devices} = $self->{devices}{array};
  }

  $self->{config}{manager}{pid} = $$;
  post_config();
} elsif ($response->{status} == 204){
  $self->{config}{manager}{pid} = $$;
  $logger->warn("Connected but not registered");
  $logger->info("Falling back to local config");
  $logger->debug({filter => \&Data::Dumper::Dumper,
                  value  => $response}) if ($logger->is_debug());

  # Run all connected devices - need to get devices to return an array
  if ($self->{config}{devices} eq 'all') {
    $self->{config}{devices} = $self->{devices}{array};
  }
  post_config();
} else {
  chomp $response->{content};
  $self->{config}{manager}{pid} = $$;
  $logger->warn("Failed to connect: $response->{content}");
  $logger->info("Falling back to local config");
  $logger->debug({filter => \&Data::Dumper::Dumper,
                  value  => $response}) if ($logger->is_debug());

  # Run all connected devices - need to get devices to return an array
  if ($self->{config}{devices} eq 'all') {
    $self->{config}{devices} = $self->{devices}{array};
  }
  post_config();
}

# Debug logging of data
$logger->debug({filter => \&Data::Dumper::Dumper,
                value  => $self}) if ($logger->is_debug());

# Log when started
if ($self->{config}{run}) {
  $logger->info("Manager started, starting devices");
} else {
  $logger->info("Manager started, configuration set to not start devices.");
}

# Main Daemon Loop
while ($daemons->{main}{run}) {
  # If we're restarting, we should trigger check for dvswitch
  if ($self->{config}{run} == 2) {
    $logger->info("Restart Trigged");
    $self->{dvswitch}{check} = 1;
  }

  # Process the internal commands
  api();

  # Process the roles
  foreach my $role (@{$self->{config}->{roles}}) {
    given ( $role->{role} ) {
      when ("mixer")    { mixer();  }
      when ("ingest")   { ingest(); }
      when ("stream")   { stream(); }
      when ("record")   { record(); }
    }
  }

  # 2 is the restart all processes trigger
  # $daemon->Kill_Daemon does a Kill -9, so if we get here they procs should be dead. 
  if ($self->{config}{run} == 2) {
    $self->{config}{run} = 1;
  }

  # Until found check for dvswitch - continuously hitting dvswitch with an unknown client caused high cpu load
  unless ( $self->{dvswitch}{running} && ! $self->{dvswitch}{check} ) {
    if ( $utils->port($self->{config}->{mixer}{host},$self->{config}->{mixer}{port}) ) {
      $logger->info("DVswitch found Running");
      $self->{dvswitch}{running} = 1;
      $self->{dvswitch}{check} = 0; # We can set this to 1 and it will check dvswitch again.
    }
  }

  sleep 1;
}



# ---- SUBROUTINES ----------------------------------------------------------

sub sig_exit {
      $logger->info("manager exiting...");
      $self->{config}{run} = 0;
      $daemons->{main}{run} = 0;
      $daemon->Kill_Daemon($self->{device_control}{api}{pid}); 
}

sub sig_pipe {
    $logger->debug( "caught SIGPIPE" ) if ( $logger->is_debug() );
}

sub print_usage {
  say "
Usage: station-mgr.pl [OPTIONS]

Options:
  --no-deaemon  disable daemon

  --debug       turn on debugging
  --help        this help text
";
  exit 0;
}

# Config triggers
sub post_config {
  my $json = to_json($self);
  my %post_data = ( 
        content => $json, 
        'content-type' => 'application/json', 
        'content-length' => length($json),
  );

  my $post = $http->post("http://127.0.0.1:3000/internal/settings", \%post_data);
  $logger->info("Config Posted to API");
  $logger->debug({filter => \&Data::Dumper::Dumper,
                value  => $post}) if ($logger->is_debug());
  return;
}

sub get_config {
  my $get = $http->get("http://127.0.0.1:3000/internal/settings");
  my $content = from_json($get->{content});
  $self->{config} = $content->{config};
  $logger->debug({filter => \&Data::Dumper::Dumper,
                value  => $get}) if ($logger->is_debug());
  $logger->debug({filter => \&Data::Dumper::Dumper,
                value  => $self}) if ($logger->is_debug());
  $logger->info("Config recieved from API");
  write_config();
  return;
}

sub write_config {
  $stationconfig->{config} = $self->{config};
  $stationconfig->write;
  $logger->info("Config written to disk");
  return;
}

## api 
sub api {
  my $device;
  unless ($logger->is_debug()) {
    $self->{device_commands}{api}{command} = "$Bin/station-api.pl --daemon --environment production";
  } else{
    $self->{device_commands}{api}{command} = "$Bin/station-api.pl";
  }
  $device->{role} = "api";
  $device->{id} = "api";
  $device->{type} = "internal";
  run_stop($device);
  return;
}

## Ingest
sub ingest {
  if ($self->{dvswitch}{running} == 1) {
    foreach my $device (@{$self->{config}{devices}}) {
      $device->{role} = "ingest";
      run_stop($device);
    }
  }
  return;
}

## Mixer
sub mixer {
  my $device;
  $device->{role} = "mixer";
  $device->{id} = "dvswitch";
  $device->{type} = "mixer";
  run_stop($device);
  return;
}

## Stream
sub stream {
  my $device;
  $device->{role} = "stream";
  $device->{id} = $self->{config}{stream}{stream};
  $device->{type} = "stream";
  run_stop($device);
  return;
}

## Record
sub record {
  my $device;
  unless(-d "$self->{config}{record_path}") {
    make_path("$self->{config}{record_path}");
  }
  $device->{role} = "record";
  $device->{id} = "record";
  $device->{type} = "record";
  run_stop($device);
  return;
}

# run, stop or restart a process 
sub run_stop {
  my ($device) = @_;
  my $time = time;

  # Build command for execution and save it for future use
  unless ($self->{device_commands}{$device->{id}}{command}) {
    given ($device->{role}) {
      when ("ingest")   { 
        $self->{device_commands}{$device->{id}}{command} = ingest_commands($device->{id},$device->{type});
        $logger->debug("Command for $device->{id} - $device->{type}: $self->{device_commands}{$device->{id}}{command}") if ($logger->is_debug());
      }
      when ("mixer")    { 
        $self->{device_commands}{$device->{id}}{command} = mixer_command(); 
        $logger->debug("Command for $device->{id} - $device->{type}: $self->{device_commands}{$device->{id}}{command}") if ($logger->is_debug());
      }
      when ("stream")   { 
        $self->{device_commands}{$device->{id}}{command} = stream_command($device->{id},$device->{type}); 
        $logger->debug("Command for $device->{id} - $device->{type}: $self->{device_commands}{$device->{id}}{command}") if ($logger->is_debug());
      }
      when ("record")   { 
        $self->{device_commands}{$device->{id}}{command} = record_command($device->{id},$device->{type}); 
        $logger->debug("Command for $device->{id} - $device->{type}: $self->{device_commands}{$device->{id}}{command}") if ($logger->is_debug());
      }
    }
  }

  # Prevent the service from running if failed to many times in a short period of time
  if ( $self->{config}{device_control}{$device->{id}}{run} && (($time - $self->{device_control}{$device->{id}}{timestamp} < 30) && $self->{device_control}{$device->{id}}{runcount} > 5 )) {
    $logger->warn("$device->{id} failed to start too many times, stopping.");
    $self->{config}{device_control}{$device->{id}}{run} = 0;
    $logger->warn("Command for $device->{id} - $device->{type}: $self->{device_commands}{$device->{id}}{command}");
    # status flag
    post_config();
  }
  
  # If we're supposed to be running, run.
  if (($self->{config}{run} == 1 && 
  (! defined $self->{config}{device_control}{$device->{id}}{run} || $self->{config}{device_control}{$device->{id}}{run} == 1)) ||
  $device->{type} eq 'internal') {
    # The failed service check depends on a run flag being set, if we got here it should be 1.
    $self->{config}{device_control}{$device->{id}}{run} = 1;

    # Get the running state + pid if it exists
    my $state = $utils->get_pid_command($device->{id},$self->{device_commands}{$device->{id}}{command},$device->{type}); 

    unless ($state->{running}) {
      # Run Count and timestamp to prevent failing services going undected
      if ( ! defined $self->{device_control}{$device->{id}}{timestamp} ) {
        $self->{device_control}{$device->{id}}{timestamp} = $time;
        $self->{device_control}{$device->{id}}{runcount} = 1;
        $logger->debug("Timestamp and Run Count initialised for $device->{id}");
      } else {
        $logger->warn("$device->{id} failed to start, incrementing run count. Current count $self->{device_control}{$device->{id}}{runcount}");
        $self->{device_control}{$device->{id}}{runcount}++;
      }
      
      # log dvswitch start or  device connecting 
      unless ($device->{type} eq "mixer") {
        $logger->info("Connect $device->{id} to DVswitch");
      } else {
        $logger->info("Starting DVswitch");
      }
      
      # Spawn the Ingest Command
      my %proc_opts;
      unless ($logger->is_debug()) {
        %proc_opts = (
           exec_command => $self->{device_commands}{$device->{id}}{command},
        );
      } else {
        %proc_opts = (
           child_STDOUT => "/tmp/$device->{id}-STDOUT.log",
           child_STDERR => "/tmp/$device->{id}-STDERR.log", 
           exec_command => $self->{device_commands}{$device->{id}}{command},
        );
      }       
      my $proc = $daemon->Init( \%proc_opts );

      # give the process some time to settle
      sleep 1;
      # Set the running state + pid
      $state = $utils->get_pid_command($device->{id},$self->{device_commands}{$device->{id}}{command},$device->{type}); 
      $logger->debug({filter => \&Data::Dumper::Dumper,
                      value  => $state}) if ($logger->is_debug());
    }
    
    # If state has changed set it and post the config
    if (! defined $self->{device_control}{$device->{id}}{running} || 
      ($self->{device_control}{$device->{id}}{running} != $state->{running})) {
      $self->{device_control}{$device->{id}}{pid} = $state->{pid};
      $self->{device_control}{$device->{id}}{running} = $state->{running};
      post_config();
    }

  } elsif (defined $self->{device_control}{$device->{id}}{pid}) {
    # Kill The Child
    if ($daemon->Kill_Daemon($self->{device_control}{$device->{id}}{pid})) { 
      $logger->info("Stop $device->{id}");
      $self->{device_control}{$device->{id}}{running} = 0;
      $self->{device_control}{$device->{id}}{pid} = undef; 
      post_config();
    }

    # Restart Run count and timestamp
    $self->{device_control}{$device->{id}}{timestamp} = undef;
    $self->{device_control}{$device->{id}}{runcount} = 0;

  }

  # Set device back to running if a restart was triggered
  if ($self->{config}{device_control}{$device->{id}}{run} == 2) {
    $logger->info("Restarting $device->{id}");
    $self->{config}{device_control}{$device->{id}}{run} = 1;
    write_config();
    post_config();
  }

  return;
}

## Commands
sub ingest_commands {
  my ($id,$type) = @_;
  my $command = $self->{commands}{$type};
  my $did;

  # Files aren't part of the device list returned by Devices.pm
  unless ($type eq "file") {
    $did = $self->{devices}{$type}{$id}{device};
  } else {
    $did = $id;
  }

  my %cmd_vars =  ( 
                    device  => $did,
                    host    => $self->{config}{mixer}{host},
                    port    => $self->{config}{mixer}{port},
                  );

  $command =~ s/\$(\w+)/$cmd_vars{$1}/g;

  return $command;
} 

sub mixer_command {
  my ($id,$type) = @_;
  my $command = $self->{commands}{dvswitch};
  my %cmd_vars =  ( 
                    port    => $self->{config}{mixer}{port},
                  );

  $command =~ s/\$(\w+)/$cmd_vars{$1}/g;

  return $command;
} 

sub record_command {
  my ($id,$type) = @_;
  my $command = $self->{commands}{record};
  my %cmd_vars =  ( 
                    host      => $self->{config}{mixer}{host},
                    port      => $self->{config}{mixer}{port},
                    room      => $self->{config}{room},
                    path      => $self->{config}{record_path},
                  );

  $command =~ s/\$(\w+)/$cmd_vars{$1}/g;

  return $command;
} 

sub stream_command {
  my ($id,$type) = @_;
  my $command = $self->{commands}{stream};
  my %cmd_vars =  ( 
                    host      => $self->{config}{mixer}{host},
                    port      => $self->{config}{mixer}{port},
                    id        => $id,
                    shost     => $self->{config}{stream}{host},
                    sport     => $self->{config}{stream}{port},
                    spassword => $self->{config}{stream}{password},
                    stream    => $self->{config}{stream}{stream},
                  );

  $command =~ s/\$(\w+)/$cmd_vars{$1}/g;

  return $command;
} 

# Get Mac Address
sub getmac {
  # This is better, but can break if no eth0. We are only using it as a UID - think of something better.
  my $macaddress = `ifdata -ph eth0`;
  chomp $macaddress;
  return $macaddress;
}

__END__

(dev) bofh-sider:~/git/eventstreamr/station $ ps waux|grep dv
leon     19898  2.5  0.1 850956 24560 pts/12   Sl+  11:35   1:21 dvswitch -h localhost -p 1234
leon     20723  0.0  0.0   4404   612 ?        S    12:27   0:00 sh -c ffmpeg -f video4linux2 -s vga -r 25 -i /dev/video0 -target pal-dv - | dvsource-file /dev/stdin -h localhost -p 1234
leon     20724  8.0  0.1 130680 24884 ?        S    12:27   0:01 ffmpeg -f video4linux2 -s vga -r 25 -i /dev/video0 -target pal-dv -
leon     20725  0.1  0.0  10796   860 ?        S    12:27   0:00 dvsource-file /dev/stdin -h localhost -p 1234
leon     20735  0.0  0.0   9396   920 pts/16   S+   12:28   0:00 grep --color=auto dv

$VAR1 = {
          'commands' => {
                          'alsa' => 'dvsource-alsa -h $host -p $port hw:$device',
                          'dv' => 'dvsource-firewire -h $host -p $port -c $device',
                          'record' => 'dvsink-files $device',
                          'v4l' => 'ffmpeg -f video4linux2 -s vga -r 25 -i $device -target pal-dv - | dvsource-file /dev/stdin -h $host -p $port',
                          'stream' => 'dvsink-command -- ffmpeg2theora - -f dv -F 25:2 --speedlevel 0 -v 4  --optimize -V 420 --soft-target -a 4 -c 1 -H 44100 -o - | oggfwd $host $port 8000 $password /$stream',
                          'file' => 'dvsource-file -l $device',
                          'dvswitch' => 'dvswitch -h 0.0.0.0 -p $port'
                        },
          'config' => {
                        'roles' => [
                                     {
                                       'role' => 'ingest'
                                     },
                                     {
                                       'role' => 'mixer'
                                     },
                                     {
                                       'role' => 'stream'
                                     }
                                   ],
                        'nickname' => 'test',
                        'room' => 'room1',
                        'devices' => [
                                       {
                                         'name' => 'Chicony Electronics Co.  Ltd. ASUS USB2.0 Webcam',
                                         'id' => 'video0',
                                         'type' => 'v4l',
                                         'device' => '/dev/video0'
                                       },
                                       {
                                         'name' => 'C-Media Electronics, Inc. ',
                                         'usbid' => '0d8c:0008',
                                         'id' => '2',
                                         'type' => 'alsa',
                                         'device' => '2'
                                       }
                                     ],
                        'device_control' => {
                                              'video0' => {
                                                            'run' => '0'
                                                          }
                                            },
                        'run' => '0',
                        'macaddress' => '00:15:58:d8:85:c7',
                        'mixer' => {
                                     'port' => '1234',
                                     'host' => 'localhost'
                                   }
                      },
          'dvswitch' => {
                          'check' => 1
                        },
          'devices' => {
                         'array' => [
                                      {
                                        'name' => 'Chicony Electronics Co.  Ltd. ASUS USB2.0 Webcam',
                                        'id' => 'video0',
                                        'type' => 'v4l',
                                        'device' => '/dev/video0'
                                      },
                                      {
                                        'name' => 'C-Media Electronics, Inc. ',
                                        'usbid' => '0d8c:0008',
                                        'id' => '2',
                                        'type' => 'alsa',
                                        'device' => '2'
                                      }
                                    ],
                         'dv' => {
                                   'all' => []
                                 },
                         'alsa' => {
                                     '2' => {
                                              'name' => 'C-Media Electronics, Inc. ',
                                              'usbid' => '0d8c:0008',
                                              'id' => '2',
                                              'type' => 'alsa',
                                              'device' => '2'
                                            },
                                     'all' => [
                                                {
                                                  'name' => 'C-Media Electronics, Inc. ',
                                                  'usbid' => '0d8c:0008',
                                                  'id' => '2',
                                                  'type' => 'alsa',
                                                  'device' => '2'
                                                }
                                              ]
                                   },
                         'v4l' => {
                                    'video0' => {
                                                  'name' => 'Chicony Electronics Co.  Ltd. ASUS USB2.0 Webcam',
                                                  'id' => 'video0',
                                                  'type' => 'v4l',
                                                  'device' => '/dev/video0'
                                                },
                                    'all' => [
                                               {
                                                 'name' => 'Chicony Electronics Co.  Ltd. ASUS USB2.0 Webcam',
                                                 'id' => 'video0',
                                                 'type' => 'v4l',
                                                 'device' => '/dev/video0'
                                               }
                                             ]
                                  },
                         'all' => {
                                    'video0' => {
                                                  'name' => 'Chicony Electronics Co.  Ltd. ASUS USB2.0 Webcam',
                                                  'id' => 'video0',
                                                  'type' => 'v4l',
                                                  'device' => '/dev/video0'
                                                },
                                    'all' => [
                                               {
                                                 'name' => 'C-Media Electronics, Inc. ',
                                                 'usbid' => '0d8c:0008',
                                                 'id' => '2',
                                                 'type' => 'alsa',
                                                 'device' => '2'
                                               }
                                             ],
                                    '2' => {
                                             'name' => 'C-Media Electronics, Inc. ',
                                             'usbid' => '0d8c:0008',
                                             'id' => '2',
                                             'type' => 'alsa',
                                             'device' => '2'
                                           }
                                  }
                       }
        };