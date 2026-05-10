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
use HTTP::Tiny;

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
sub usage;
sub getRadioCurrentListeners;

# +---------------------------------------------------------------------------+
# !          MAIN                                                             !
# +---------------------------------------------------------------------------+

# Check command line parameters
my $result = GetOptions (
        "host=s"   => \$RADIO_HOSTNAME,
        "port=s"   => \$RADIO_PORT,
        "source=i" => \$RADIO_SOURCE,
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
sub usage {
    my ($strErr) = @_;
    if (defined($strErr)) {
            print STDERR "Error : " . $strErr . "\n";
    }
    print STDERR "Usage: " . basename($0) . " --host <radio_hostname> --port <radio_port> [--source <radio_source default: 0>]\n";
    exit 4;
}

sub getRadioCurrentListeners {
	unless (defined($RADIO_HOSTNAME) && ($RADIO_HOSTNAME ne "")) {
		usage("RADIO_HOSTNAME not set");
	}

	unless (defined($RADIO_PORT) && ($RADIO_PORT ne "")) {
		usage("RADIO_PORT not set");
	}

	unless (defined($RADIO_SOURCE) && $RADIO_SOURCE =~ /^\d+$/) {
		print STDERR "Invalid --source value: must be a non-negative integer\n";
		return "N/A";
	}

	my $url = "http://$RADIO_HOSTNAME:$RADIO_PORT/$RADIO_JSON";
	my $response = eval { HTTP::Tiny->new(timeout => 5)->get($url) }
	            // { success => 0, status => 0, reason => $@ };

	unless ($response->{success}) {
		my $status = $response->{status} // 0;
		my $reason = $response->{reason} // '';
		print STDERR "Error while retrieving JSON $url: HTTP $status $reason\n";
		return "N/A";
	}

	my $line = $response->{content};
	unless (defined($line) && $line ne "") {
		print STDERR "Empty Icecast JSON response from $url\n";
		return "N/A";
	}

	chomp($line);

	my $json = eval { decode_json($line) };
	if ($@ || ref($json) ne 'HASH') {
		my $err = $@ || 'decoded JSON is not a HASH';
		chomp($err);
		print STDERR "Invalid Icecast JSON from $url: $err\n";
		return "N/A";
	}

	my $icestats = ref($json->{'icestats'}) eq 'HASH' ? $json->{'icestats'} : undef;
	unless (defined($icestats)) {
		print STDERR "Invalid Icecast JSON from $url: missing icestats object\n";
		return "N/A";
	}

	my $sources = $icestats->{'source'};
	my $selected_source;

	if (ref($sources) eq 'ARRAY') {
		if ($RADIO_SOURCE > $#$sources) {
			print STDERR "Invalid --source index $RADIO_SOURCE: Icecast returned only " . scalar(@{$sources}) . " source(s)\n";
			return "N/A";
		}

		$selected_source = $sources->[$RADIO_SOURCE];
	}
	elsif (ref($sources) eq 'HASH') {
		$selected_source = $sources;
	}
	else {
		print STDERR "Invalid Icecast JSON from $url: missing source object/array\n";
		return "N/A";
	}

	unless (defined($selected_source) && ref($selected_source) eq 'HASH') {
		print STDERR "Invalid Icecast source selection for source index $RADIO_SOURCE\n";
		return "N/A";
	}

	my $listeners = $selected_source->{'listeners'};
	return defined($listeners) && $listeners ne "" ? $listeners : "N/A";
}
