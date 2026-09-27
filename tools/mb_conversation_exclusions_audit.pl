#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use Mediabot::AI::ConversationAudit qw(audit_exclusions);

my ($config, $channel, $bot_nick);
my (@commands, @bots);
my $usage = 'Usage: perl tools/mb_conversation_exclusions_audit.pl '
    . '--config FILE --channel #channel --bot-nick NICK '
    . '[--command !word ...] [--bot NICK ...]';

GetOptions(
    'config=s'   => \$config,
    'channel=s'  => \$channel,
    'bot-nick=s' => \$bot_nick,
    'command=s@' => \@commands,
    'bot=s@'     => \@bots,
) or die "$usage\n";
die "$usage\n" if @ARGV || !defined($config) || !defined($channel)
    || !defined($bot_nick) || !(@commands || @bots);

# Use the same Config::Simple-backed reader and classification engine as the
# running bot. Never print the config object, its path, or message bodies.
my $conf = eval {
    require Mediabot::Conf;
    Mediabot::Conf->new(undef, $config);
};
die "[KO] Config could not be read.\n" if $@ || !$conf;

my $report = audit_exclusions(
    conf => $conf, channel => $channel, bot_nick => $bot_nick,
    commands => \@commands, bots => \@bots,
);
die "[KO] Audit input or classification unavailable.\n"
    unless $report->{ok};

print "[AUDIT] $report->{channel}: ",
    "commands=$report->{command_total} missing=", scalar @{ $report->{missing_commands} },
    " bots=$report->{bot_total} missing=", scalar @{ $report->{missing_bots} },
    ' ordinary=', ($report->{ordinary_visible} ? 'visible' : 'excluded'), "\n";
print '[MISSING] commands: ', join(' ', @{ $report->{missing_commands} }), "\n"
    if @{ $report->{missing_commands} };
print '[MISSING] bot sender/address: ', join(' ', @{ $report->{missing_bots} }), "\n"
    if @{ $report->{missing_bots} };

exit(@{ $report->{missing_commands} } || @{ $report->{missing_bots} }
    || !$report->{ordinary_visible} ? 2 : 0);
