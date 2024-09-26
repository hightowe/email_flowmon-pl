#!/usr/bin/perl

########################################################################
# A program to test email flow from origin to destination.
#
# This program sends an email to a specified address via sendmail and
# then monitors an IMAP folder for that email to arrive. If the email
# arrives within the time constraint, it is deleted and this program
# is silent. If not, this program complains.
#
# The program operates via a config file that is a simple Perl hash.
# An example config should accompany the program.
#
# The original motivation for this program was a glitch at my email
# provider that led to emails not being forwarded and it took a few
# days for me to notice. Now I use this program to monitor that email
# flow end-to-end.
#
# Originally written September 24, 2024, by Lester Hightower and
# on Linux Mint 21. It should work on most Unix flavors.
########################################################################

use strict;
use warnings;
use feature qw(signatures);
no warnings qw(experimental::signatures);
use Getopt::Long;
use Data::Dumper;
use Cwd 'abs_path';
use File::Slurp;
use File::Basename qw(basename);
use Net::IMAP::Simple 1.2209; # libnet-imap-simple-ssl-perl (some older version *may* work)
use IO::Socket::SSL;          # libio-socket-ssl-perl
use Email::Simple;            # libemail-simple-perl
use MIME::Lite;               # libmime-lite-perl

$| = 1; # no buffering on stdio

my $APP_NAME = basename(abs_path($0));
our $opts = MyGetOpts(); # Will only return with options we think we can use
my $VERBOSE = $opts->{verbose};

# Load our config into $conf
my $conf_text = read_file($opts->{conf});
my $conf = eval($conf_text);
my @conf_errs = ();
push @conf_errs, "Bad config file" if (ref($conf) ne 'HASH');
foreach my $k (qw( imap test_address sendmail_exe )) {
  push @conf_errs, "Missing $k" if (!exists($conf->{imap}));
}
push @conf_errs, "Missing sendmail_exe binary" if (! -x $conf->{sendmail_exe});
die "Conf errors: ".Dumper(\@conf_errs)."\n" if (scalar(@conf_errs) > 0);
#print Dumper($conf)."\n";

# Build the MIME::Lite email object for our test email...
my $randnum = ''; while (length($randnum) < 10) { $randnum .= int(rand(10)) }
my $test_subject = basename(abs_path($0)) . " test email " . sprintf("%x%x", $randnum, scalar reverse("$randnum"));
#print "SUBJECT: $test_subject\n"; exit;
my $email_msg = MIME::Lite->new(
	#From     => $from,
	To       => $conf->{test_address},
	Subject  => $test_subject,
	Data     => "This is an automated message.\n",
	Type     => "text/plain", # No need to HTML
     );

# Connect to the IMAP server, log on, and select the proper folder
my $imap = Net::IMAP::Simple->new($conf->{imap}->{host},
                #debug => 'warn', # Debugging output
                use_ssl => 1,
                ssl_options => [
                        verify_hostname => 0,
                        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
                                 ]) ||
	die "Unable to connect to IMAP: $Net::IMAP::Simple::errstr\n";
if(!$imap->login($conf->{imap}->{user},$conf->{imap}->{pass})){
  die "IMAP login failed: " . $imap->errstr . "\n";
}
my $nm = $imap->select($conf->{imap}->{folder}) ||
	die "IMAP select folder failed: " . $imap->errstr . "\n";

# Having successfully connected to the IMAP server, we can send our test email.
# See the perldoc of MIME::Lite for how these sendmail options were chosen.
$email_msg->send('sendmail', "$conf->{sendmail_exe} -t -oi -oem") || die "Failed to send test email";
printf("Test email sent: %s\n", $test_subject) if ($VERBOSE);

# With the test email now sent, we now need to look for its arrival via IMAP
my $max_time_to_try = $conf->{constraints}->{max_time_to_try} // 30;
my $retry_freq = $conf->{constraints}->{retry_frequency} // 5;
my $time_left = $max_time_to_try;
my $success = 0;
TRIES: while (($time_left -= $retry_freq) > 0) {
  sleep($retry_freq);
  if (my $msgnum = find_email_with_subject($imap, $test_subject)) {
    # Delete the msgnum (our test message)
    if (! $imap->delete($msgnum)) {
      die "Failed to delete my test message: " . $imap->errstr . "\n";
    }
    $success = 1; # Declare success
    last TRIES;   # End the retry loop
  }
}

$imap->quit; # Also expunges the mailbox

if ($success) {
  my $time_used = $max_time_to_try - $time_left;
  print "Test was successful in $time_used seconds.\n" if ($VERBOSE);
  exit 0;
}

die "The test email to $conf->{test_address} did not appear on the IMAP server within $max_time_to_try seconds.\n";

#########################################################################
#########################################################################
#########################################################################

# Returns the message number of the first message found that matches
# the given subject. Note that the $imap->select() calls are required
# in both of these else they just look at a static snapshot of the
# folder and will not see new messages that have arrived. This code
# was originally written to just crawl, but searching is much faster
# if the IMAP server allows it and the folder has many messages.
sub find_email_with_subject($imap, $subject) {
  #return find_email_with_subject_crawl($imap, $subject);
  return find_email_with_subject_search($imap, $subject);
}
sub find_email_with_subject_search($imap, $subject) {
  my $nm = $imap->select($imap->current_box) ||
	die "IMAP select of current_box failed: " . $imap->errstr . "\n";
  my @msg_ids = $imap->search_subject($subject);
  printf("IMAP search found: %d\n", scalar(@msg_ids)) if ($VERBOSE);
  return($msg_ids[0]) if (scalar(@msg_ids) == 1); # If we found 1 msg, return it
}
sub find_email_with_subject_crawl($imap, $subject) {
  # Loop over all of the messages
  my $nm = $imap->select($imap->current_box) ||
	die "IMAP select of current_box failed: " . $imap->errstr . "\n";
  for(my $i = 1; $i <= $nm; $i++){
    my $seen = ' '; $seen = "*" if($imap->seen($i));
    my $es = Email::Simple->new(join '', @{ $imap->top($i) } );
    my $msgsubj = $es->header('Subject');
    printf("$seen [%03d] %s\n", $i, $msgsubj) if ($VERBOSE);
    #warn "LHHD: $i - *$msgsubj* vs *$subject*\n";
    return $i if ($es->header('Subject') eq $subject); # Success (return msgnum)
  }
  return 0; # Did not find a match...
}

# Get and validate command line options
sub MyGetOpts {
  my %opts=();
  my @params = ( "conf=s", "verbose", "help", "h", );
  my $result = &GetOptions(\%opts, @params);

  my $use_help_msg = "Use --help to see information on command line options.";

  # Set any undefined booleans to 0
  foreach my $param (@params) {
    if ($param !~ m/=/ && (! defined($opts{$param}))) {
      $opts{$param} = 0; # Booleans
    }
  }

  # If the user asked for help give it and exit
  if ($opts{help} || $opts{h}) {
    print GetUsageMessage();
    exit;
  }

  # If GetOptions failed it told the user why, so let's exit.
  if (! int($result)) {
    print "\n" . $use_help_msg . "\n";
    exit;
  }

  my @errs=(); # Collects any errors that we find

  # If the user didn't provide a --conf, set the default. Validate either way.
  if (! exists($opts{conf})) {
    my $conf_path = abs_path($0);
    $conf_path =~ s/[.][^.]+$/.conf/;
    push(@errs, "No --conf and $conf_path is unreadable\n") if (! -f -r $conf_path);
    $opts{conf} = $conf_path;
  } else {
    push(@errs, "-conf = $opts{conf} is unreadable\n") if (! -f -r $opts{conf});
  }

  if (scalar(@errs)) {
    warn "There were errors:\n" .
        "  " . join("\n  ", @errs) . "\n\n";
    print $use_help_msg . "\n";
    exit;
  }

  return \%opts;
}

# The message that users get from --help
sub GetUsageMessage {
  my $parmlen = 14;
  my $col1len = $parmlen + 3;
  my $pwlen = our $DEFAULT_PASSWD_LEN;
  my @params = (
    [ 'conf=s'  => "The config file to use." ],
    [ 'verbose' => 'Be verbose, else be silent except on failure.' ],
    [ help         => 'This message.' ],
  );
  my $t="Usage: $APP_NAME [--conf=<file.conf>]\n" .
  "\n";
  foreach my $param (@params) {
    my $fmt = '  %-'.$parmlen.'s %s';
    $t .= sprintf("$fmt\n", '--'.$param->[0], $param->[1]);
  }
  return $t;
}

