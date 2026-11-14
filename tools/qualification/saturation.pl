#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../..", "$FindBin::Bin/../../t/lib";
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use JSON::PP;
use Test::More;
use MB1300SaturationProbe;
@ARGV==1 or die "Usage: saturation.pl NEW_REPORT_JSON\n";
sysopen(my $out,$ARGV[0],O_WRONLY|O_CREAT|O_EXCL,0600) or die "Cannot create report: $!\n";
my $report=eval {MB1300SaturationProbe::run()};
my $error=$@;
$report ||= {schema=>1,error=>$error};
$report->{status}=!$error && Test::More->builder->is_passing ? 'passed':'failed';
print {$out} JSON::PP->new->canonical->pretty->encode($report) or die $!;
close $out or die $!;
die $error if $error;
done_testing;
