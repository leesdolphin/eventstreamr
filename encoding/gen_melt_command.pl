#!/usr/bin/perl

use v5.14;
use JSON; # libjson-perl
use Getopt::Long;
use HTTP::Tiny; # libhttp-tiny-perl
use Data::Dumper;
use DateTime::Format::Strptime;
use Cache::FileCache;
use File::Basename 'basename';
use Image::Magick;
use File::Path qw(make_path);

# +- Range in seconds 
our $self;
$self->{range} = 1500;
$self->{default_expires} = 300;
$self->{cache_root} = '/tmp/schedule/';
# tmp on main disk, scp to.
$self->{output_tmp} = '/encode_tmp';
# secondary output
$self->{output_root} = '/encode_final';
# process queue
$self->{queue} = '/tmp';
$self->{remote_storage} = 'av@10.4.4.20:';

if (! -d $self->{cache_root}) {
  make_path($self->{cache_root});
}

my @files;
my $start_cut;
my $end_cut;

my $getopts_rc = GetOptions(
    "start-cut=i"     => \$start_cut,
    "files=s{,}"         => \@files,
    "end-cut=i"       => \$end_cut,

    "help|?"        => \&print_usage,
);

my @dvfiles = split(/[\s,]+/,join(',' , @files));

sub print_usage {
  say "
Usage: station-mgr.pl [OPTIONS]

Options:
  --start-cut   Seconds to cut from the start
  --end-cut     Seconds to cut from the endi
  --files       Space separated list of files, full path required

  --help        this help text
";
  exit 0;
}

# HTTP
our $http = HTTP::Tiny->new(timeout => 15);

my $test = '/tmp/2014-01-06_13-40-26.dv';
$test = basename($test);
$test =~ s/\.dv$//;

$self->{firstdv} = $test;

retrieve_schedule();

# Get the list of venues
my @venues;
my $count = 0;
foreach my $key (keys %{$self->{schedule}}) {
  say "$count) $key";
  push(@venues, $key);
  $count++;
}

my $selection = &Prompt("Select a venue: 0 - $count");
say "";

my @venue = @{$self->{schedule}{@venues[$selection]}};
$self->{venue} = @venues[$selection];

my $dvparse = DateTime::Format::Strptime->new(
  pattern => '%F_%H-%M-%S',
  on_error => 'croak',
);

my $zooparse = DateTime::Format::Strptime->new(
  pattern => '%F %H:%M:%S',
  on_error => 'croak',
);

my $starttime = $dvparse->parse_datetime($self->{firstdv});

# Find Closest schedules
$count = 0;
foreach my $presentation (@venue) {
  my $time = $zooparse->parse_datetime($presentation->{start});
  my $diff = $starttime->epoch - $time->epoch;
  if ($diff <= $self->{range} &&  $diff >= -$self->{range}) {
    say "$count) $presentation->{title}";
  }
  $count++;
}

$count--;

# Ask for Title info
my $talk = &Prompt("Select the matching talk: 0 - $count");

my $title = @venue[$talk]->{title};
my $presenters = @venue[$talk]->{presenters};

$title = &Prompt("Alter title:", "$title");
$presenters = &Prompt("Alter Prestenters", "$presenters");

if ($presenters eq 'n') {
  $self->{title_text} = "+$title.txt";
} else {
  $self->{title_text} = "$title\n$presenters";
  $self->{title_file} = "$title - $presenters.dv";
  $self->{title_mp4} = "$title - $presenters.mp4";
}

# Create titles
room_translate();
$self->{output_file} = "/tmp/@venue[$talk]->{schedule_id}-title.png";
create_title();

my @transferred;
open my $fh, ">", "$self->{queue}/@venue[$talk]->{schedule_id}.sh" or die $!;

print $fh "#!/bin/bash\n";
print $fh "mkdir -p $self->{output_root}/$self->{room}/\n";
print $fh "mkdir -p $self->{output_tmp}/$self->{room}/@venue[$talk]->{schedule_id}\n\n";
my $count;
foreach my $file (@dvfiles) {
  print $fh "scp $self->{remote_storage}$file $self->{output_tmp}/$self->{room}/@venue[$talk]->{schedule_id}/$file\n";
  push(@transferred, "$self->{output_tmp}/$self->{room}/@venue[$talk]->{schedule_id}/$file");
  $count++;
}
print $fh "scp $self->{remote_storage}$self->{queue}/@venue[$talk]->{schedule_id}.sh $self->{output_tmp}/$self->{room}/@venue[$talk]->{schedule_id}/.\n";
print $fh "\n";
$count--;
my $startdv = $transferred[0];
my $enddv = $transferred[$count];
shift(@transferred);
pop(@transferred);

if ($start_cut) {
  print $fh "dd if=$startdv ibs=36000000 skip=$start_cut of=$self->{output_tmp}/$self->{room}/@venue[$talk]->{schedule_id}/start-@venue[$talk]->{schedule_id}.dv\n";
  $startdv = "$self->{output_tmp}/$self->{room}/start-@venue[$talk]->{schedule_id}.dv";
}

if ($end_cut) {
  print $fh "dd if=$enddv ibs=36000000 count=$end_cut of=$self->{output_tmp}/$self->{room}/@venue[$talk]->{schedule_id}/end-@venue[$talk]->{schedule_id}.dv\n";
  #print $fh "tail -c \$(( 3515.625 * $end_cut )) $enddv $self->{output_tmp}/$self->{room}/end-@venue[$talk]->{schedule_id}.dv\n";
  $enddv = "$self->{output_tmp}/$self->{room}/end-@venue[$talk]->{schedule_id}.dv";
}


print $fh "\n";

print $fh "melt $self->{output_root}/lca2014-intro.dv -filter watermark:$self->{output_file} in=300 out=500 composite.progressive=1 producer.align=centre composite.valign=c composite.halign=c $startdv @transferred $enddv $self->{output_root}/lca2014-exit.dv -consumer avformat:\"$self->{output_root}/$self->{room}/$self->{title_file}\"\n";
print $fh "\n";
print $fh "ffmpeg -i \"$self->{output_root}/$self->{room}/$self->{title_file}\" -vf yadif=1 -threads 0 -acodec libfdk_aac -ab 96k -ac 1 -ar 48000 -vcodec libx264 -preset slower -crf 26 \"$self->{output_root}/$self->{room}/$self->{title_mp4}\"\n";
close $fh;

sub Prompt { # inspired from here: http://alvinalexander.com/perl/edu/articles/pl010005
  my ($question,$default) = @_;
  if ($default) {
    print $question, "[", $default, "]: ";
  } else {
    print $question, ": ";
  }

  $| = 1;               # flush
  $_ = <STDIN>;         # get input

  chomp;
  if ("$default") {
    return $_ ? $_ : $default;    # return $_ if it has a value
  } else {
    return $_;
  }
}

sub create_title {
  my $im;
  $im = new Image::Magick;
  
  $im->Set( size => '768x200' );
  $im->ReadImage('/tmp/blank_title.png');
  
  my $label=Image::Magick->new(size=>"700x200");
  $label->Set(gravity => "Center", font => '/usr/share/fonts/truetype/ubuntu-font-family/Ubuntu-B.ttf', background => 'none', fill => 'white');
  $label->Read("label:$self->{title_text}");
  $im->Composite(image => $label, gravity => 'Center');
  $im->Write("$self->{output_file}");
}

sub retrieve_schedule {
  my $cache = new Cache::FileCache( {namespace  => 'schedule_cache', default_expires_in => $self->{default_expires}, cache_root => $self->{cache_root} } );
  $self->{raw_json} = $cache->get( 'schedule' );
  $self->{cache} = 'Cached';
  if ( not defined $self->{raw_json} ) {
    my $response =  $http->get("https://lca2014.linux.org.au/programme/schedule/json");
    if ($response->{status} != 200 ) {
      say "Schedule data not available";
      say "$response->{status}";
      say "$response->{content}";
      exit 0;
    }
    $self->{raw_json} = $response->{content};
    $cache->set( 'schedule', $self->{raw_json} );
    $self->{cache} = 'Fresh';
  }
  $self->{schedule} = from_json($self->{raw_json});
  return;
}

# make this configurable
sub room_translate {
  given($self->{venue}) {
    when  (/GGGL:GENTILLI Gentilli Lecture Theatre/) { $self->{room} = 'gentilli';}
    when  (/Royal Perth Yacht Club - Australia II Drive, Crawley/) { $self->{room} = 'Royal Perth Yacht Club - Australia II Drive, Crawley';}
    when  (/ENG:LT2/) { $self->{room} = 'eng-lt1';}
    when  (/Hardware room - Physics Lab 1.28/) { $self->{room} = 'Hardware room - Physics Lab 1.28';}
    when  (/Foyer/) { $self->{room} = 'Foyer';}
    when  (/Octagon/) { $self->{room} = 'octagon';}
    when  (/Prescott Court, UWA/) { $self->{room} = 'Prescott Court, UWA';}
    when  (/GPB2:LT Robert Street Lecture Theatre/) { $self->{room} = 'roberts';}
    when  (/uncatered/) { $self->{room} = 'uncatered';}
    when  (/GGGL:WOOL Woolnough Lecture Theatre/) { $self->{room} = 'wool';}
    when  (/Matilda Bay foreshore/) { $self->{room} = 'Matilda Bay foreshore';}
    when  (/GGGL:WEBB Webb Lecture Theatre/) { $self->{room} = 'webb';}
    when  (/All Lecture Theatres/) { $self->{room} = 'All Lecture Theatres';}
    when  (/ENG:LT1/) { $self->{room} = 'eng-lt1';}
  }
}
