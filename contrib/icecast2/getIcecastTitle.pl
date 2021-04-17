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
sub getRadioCurrentSong(@);

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

my $title;
unless (defined($title=getRadioCurrentSong()) && ($title ne "N/A")) {
	print STDERR "Could not get title for $RADIO_HOSTNAME:$RADIO_PORT\n";
	exit 2;
}
else {
	print "$title\n";
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

sub getRadioCurrentSong(@) {
	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		print STDERR "RADIO_HOSTNAME not set";
		return undef;
	}
	unless (open ICECAST_STATUS_JSON, "curl -f -s http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON |") {
		return "N/A";
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
			if (defined($source{'title'})) {
				return $source{'title'};
			}
			elsif (defined($source{'server_description'})) {
				return $source{'server_description'};
			}
			elsif (defined($source{'server_name'})) {
				return $source{'server_name'};
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