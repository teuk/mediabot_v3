#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json);
use Mediabot::Spark::Replay qw(replay_events);

my ($config, $channel, $bot_nick, $input);
my $usage = 'Usage: perl tools/mb_spark_replay.pl --config FILE '
    . '--input JSONL --channel #channel --bot-nick NICK';
GetOptions(
    'config=s' => \$config,
    'input=s' => \$input,
    'channel=s' => \$channel,
    'bot-nick=s' => \$bot_nick,
) or die "$usage\n";
die "$usage\n" if @ARGV || !defined($config) || !defined($input)
    || !defined($channel) || !defined($bot_nick);

# Bounded offline input; do not echo malformed lines or file contents.
die "[KO] Replay input exceeds 256 KiB.\n"
    if -s $input && -s $input > 262_144;
open my $fh, '<:raw', $input or die "[KO] Replay input unavailable.\n";
my @events;
while (my $line = <$fh>) {
    die "[KO] Replay input exceeds 256 events.\n" if @events >= 256;
    die "[KO] Replay line exceeds 1024 bytes.\n" if length($line) > 1024;
    my $event = eval { decode_json($line) };
    die "[KO] Invalid replay event.\n" if $@ || ref($event) ne 'HASH';
    push @events, $event;
}
close $fh;

my $conf = eval {
    require Mediabot::Conf;
    Mediabot::Conf->new(undef, $config);
};
die "[KO] Config could not be read.\n" if $@ || !$conf;

my $report = eval {
    replay_events(conf => $conf, channel => $channel,
        bot_nick => $bot_nick, events => \@events);
};
die "[KO] Replay input or policy unavailable.\n" if $@ || !$report;

my $excluded = 0;
$excluded += $_ for values %{ $report->{excluded} };
print '[REPLAY] probes=', scalar(@{ $report->{probes} }),
    ' excluded=', $excluded,
    ' repeated_momentum=', $report->{repeated_momentum}, "\n";
for my $probe (@{ $report->{probes} }) {
    print '[PROBE] at=', $probe->{at},
        ' revival=', $probe->{revival}, '/', $probe->{revival_reason},
        '/', $probe->{revival_regime},
        ' momentum=', $probe->{momentum}, '/', $probe->{momentum_reason},
        '/', $probe->{momentum_regime}, "\n";
}
exit($report->{repeated_momentum} ? 2 : 0);
