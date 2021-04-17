#!/usr/bin/perl

# +---------------------------------------------------------------------------+
# !          MODULES                                                          !
# +---------------------------------------------------------------------------+
use strict;
use warnings;
use diagnostics;
use Getopt::Long;
use File::Basename;
use JSON;

# +---------------------------------------------------------------------------+
# !          GLOBAL VARS                                                      !
# +---------------------------------------------------------------------------+
my $RADIO_HOSTNAME;
my $RADIO_PORT;
my $RADIO_JSON = "status-json.xsl";
my $RADIO_SOURCE = 0;

# +---------------------------------------------------------------------------+
# !          SUBS DECLARATION                                                 !
# +---------------------------------------------------------------------------+
sub usage(@);
sub getRadioCurrentListeners(@);

# +---------------------------------------------------------------------------+
# !          MAIN                                                             !
# +---------------------------------------------------------------------------+

# Check command line parameters
my $result = GetOptions (
        "host=s" => \$RADIO_HOSTNAME,
        "port=s" => \$RADIO_PORT,
);

unless (defined($RADIO_HOSTNAME)) {
	usage("You must specify a radio hostname");
}

unless (defined($RADIO_PORT)) {
	usage("You must specify a radio port");
}

my $listeners;
unless (defined($listeners=getRadioCurrentListeners()) && ($listeners ne "N/A")) {
	print STDERR "Could not get number of listeners for $RADIO_HOSTNAME:$RADIO_PORT\n";
	exit 2;
}
else {
	print "$listeners\n";
}

# +---------------------------------------------------------------------------+
# !          SUBS                                                             !
# +---------------------------------------------------------------------------+
sub usage(@) {
    my ($strErr) = @_;
    if (defined($strErr)) {
            print STDERR "Error : " . $strErr . "\n";
    }
    print STDERR "Usage: " . basename($0) . "--host <radio_hostname> --port <radio_port> [--source <radio_source default : 0]\n";
    exit 4;
}

sub getRadioCurrentListeners(@) {
	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		usage("RADIO_HOSTNAME not set");
	}
	unless (open ICECAST_STATUS_JSON, "curl -f -s http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON |") {
		print STDERR "Error while retrieving JSON http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
		exit 1;
	}
	my $line;
	if (defined($line=<ICECAST_STATUS_JSON>)) {
		close ICECAST_STATUS_JSON;
		chomp($line);
		my $json = decode_json $line;
		my @sources = $json->{'icestats'}{'source'};
		#my %source = %{$sources[0][$RADIO_SOURCE]};
		if (defined($sources[0])) {
			my %source = %{$sources[0]};
			if (defined($source{'listeners'})) {
				return $source{'listeners'};
			}
			else {
				return "N/A";
			}
		}
		else {
			return undef;
		}
	}
	else {
		return "N/A";
	}
}