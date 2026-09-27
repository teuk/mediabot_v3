package Mediabot::AI::ConversationAudit;

use strict;
use warnings;
use Exporter 'import';
use Mediabot::AI::ConversationExclusion;

our @EXPORT_OK = qw(audit_exclusions);

sub _irc_fold {
    my ($nick) = @_;
    my $folded = lc($nick);
    $folded =~ tr/[]\\^/{}|~/;
    return $folded;
}

# Compare an operator-supplied command/sender inventory to the exact runtime
# classifier. No public line is injected and no message or private config value
# is returned. This is coverage evidence, not a discovery of external commands.
sub audit_exclusions {
    my (%args) = @_;
    my $channel = $args{channel};
    my $bot_nick = $args{bot_nick};
    my $commands = $args{commands};
    my $bots = $args{bots};
    return { ok => 0, error => 'invalid audit input' }
        unless $args{conf} && eval { $args{conf}->can('get') }
            && defined($channel) && !ref($channel)
            && $channel =~ /\A\#[^\s,;:=+\x00-\x1f\x7f]{1,79}\z/
            && defined($bot_nick) && !ref($bot_nick)
            && $bot_nick =~ /\A[^\s,;:=+\x00-\x1f\x7f]{1,100}\z/
            && ref($commands) eq 'ARRAY' && ref($bots) eq 'ARRAY'
            && @$commands + @$bots >= 1
            && @$commands <= 64 && @$bots <= 64;

    my (%seen_commands, %seen_bots);
    my (@commands, @bots);
    for my $command (@$commands) {
        return { ok => 0, error => 'invalid command' }
            unless defined($command) && !ref($command)
                && $command =~ /\A[!.?\/][a-z0-9][a-z0-9_.-]{0,63}\z/i;
        my $key = lc($command);
        push @commands, $key unless $seen_commands{$key}++;
    }
    for my $nick (@$bots) {
        return { ok => 0, error => 'invalid bot nick' }
            unless defined($nick) && !ref($nick)
                && $nick =~ /\A[^\s,;:=+\x00-\x1f\x7f]{1,100}\z/
                && _irc_fold($nick) ne _irc_fold($bot_nick);
        push @bots, $nick unless $seen_bots{_irc_fold($nick)}++;
    }
    @commands = sort @commands;
    @bots = sort @bots;

    my $policy = eval {
        Mediabot::AI::ConversationExclusion->new(conf => $args{conf});
    };
    return { ok => 0, error => 'exclusions unavailable' }
        if $@ || !$policy;

    my (@missing_commands, @missing_bots);
    for my $command (@commands) {
        my $result = eval { $policy->classify_public_line(
            channel => $channel, nick => 'MbAuditGuest', bot_nick => $bot_nick,
            message => "$command probe",
        ) };
        return { ok => 0, error => 'classification unavailable' }
            if $@ || ref($result) ne 'HASH';
        push @missing_commands, $command
            unless $result->{excluded}
                && ($result->{reason} // '') eq 'bot_command';
    }
    for my $nick (@bots) {
        my $sender = eval { $policy->classify_public_line(
            channel => $channel, nick => $nick, bot_nick => $bot_nick,
            message => 'probe',
        ) };
        my $address = eval { $policy->classify_public_line(
            channel => $channel, nick => 'MbAuditGuest', bot_nick => $bot_nick,
            message => "$nick: probe",
        ) };
        return { ok => 0, error => 'classification unavailable' }
            if $@ || ref($sender) ne 'HASH' || ref($address) ne 'HASH';
        push @missing_bots, $nick
            unless $sender->{excluded} && ($sender->{reason} // '') eq 'declared_bot'
                && $address->{excluded} && ($address->{reason} // '') eq 'bot_address';
    }
    my $ordinary = eval { $policy->classify_public_line(
        channel => $channel, nick => 'MbAuditGuest', bot_nick => $bot_nick,
        message => 'parlons du temps demain',
    ) };
    return { ok => 0, error => 'classification unavailable' }
        if $@ || ref($ordinary) ne 'HASH';

    return {
        ok => 1, channel => $channel,
        command_total => scalar(@commands),
        bot_total => scalar(@bots),
        missing_commands => \@missing_commands,
        missing_bots => \@missing_bots,
        ordinary_visible => $ordinary->{excluded} ? 0 : 1,
    };
}

1;
