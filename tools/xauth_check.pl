#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Getopt::Long qw(GetOptions);
use Mediabot::Conf;
use Mediabot::XAuth;
my ($file,$help)=('mediabot.conf',0);
GetOptions('conf=s'=>\$file,'help'=>\$help) or exit 2;
if($help){print "Usage: perl tools/xauth_check.pl --conf FILE\nOffline configuration check; no IRC or database connection.\n";exit 0}
if(@ARGV){print "[KO] Unexpected arguments. Use --conf FILE.\n";exit 2}
my $conf=eval{Mediabot::Conf->new({},$file)};
unless($conf){print "[KO] Configuration could not be loaded.\n";exit 1}
my $bot={conf=>$conf};my $controller=Mediabot::XAuth->new(bot=>$bot);my $s=$controller->status;
print 'Network type: ',($s->{undernet}?'Undernet-compatible (1)':'other; X authentication disabled'),"\n";
print 'Configured +x: ',($s->{want_x}?'requested':'not requested'),"\n";
print 'Periodic check: ',($s->{interval}?$s->{interval}.' seconds':'disabled; connect/manual checks retained'),"\n";
unless($s->{undernet}){print "[OK] Offline check completed; X inactive on this network type.\n";exit 0}
unless($s->{configuration_ok}){print "[KO] Missing or invalid private X service/account/password or user-mode settings. Use a server-qualified service, single-token credentials and a bounded IRC line.\n";exit 1}
print "[OK] X configuration ready. Offline only: live account and +x are not verified.\n";
