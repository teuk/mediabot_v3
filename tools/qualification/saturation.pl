#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../..", "$FindBin::Bin/../../t/lib";
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use JSON::PP;
use Test::More;
use MB1300SaturationProbe;
my $cycles=2;
if (@ARGV==3 && $ARGV[1] eq '--timed-cycles') {$cycles=pop @ARGV;pop @ARGV}
@ARGV==1 && $cycles =~ /\A[0-9]+\z/ && $cycles>=1 && $cycles<=300
    or die "Usage: saturation.pl NEW_REPORT_JSON [--timed-cycles 1..300]\n";
sysopen(my $out,$ARGV[0],O_WRONLY|O_CREAT|O_EXCL,0600) or die "Cannot create report: $!\n";
my $report=eval {
    my $r=MB1300SaturationProbe::run();
    $r->{timed_recovery}=MB1300SaturationProbe::run_timed($cycles);
    return $r;
};
my $error=$@;
$report ||= {schema=>1,error=>$error};
$report->{status}=!$error && Test::More->builder->is_passing ? 'passed':'failed';
print {$out} JSON::PP->new->canonical->pretty->encode($report) or die $!;
close $out or die $!;
die $error if $error;
done_testing;
