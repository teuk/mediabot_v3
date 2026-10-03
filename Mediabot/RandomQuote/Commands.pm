package Mediabot::RandomQuote::Commands;
use strict;
use warnings;
use Mediabot::Helpers qw(checkUserChannelLevel);
use Mediabot::RandomQuote::Runtime;

sub _runtime {
    my ($ctx)=@_;return $ctx->bot->{randomquote_runtime} ||= Mediabot::RandomQuote::Runtime->new(bot=>$ctx->bot);
}
sub _duration {
    my ($text)=@_;return undef unless defined($text) && !ref($text)
        && $text =~ /\A([1-9][0-9]{0,5})(m|h|d)?\z/i;
    my $seconds=$1 * ((!defined($2) || lc($2) eq 'm') ? 60 : lc($2) eq 'h' ? 3600 : 86400);
    return $seconds>=900 && $seconds<=604800 ? $seconds : undef;
}
sub mbRandomQuote_ctx {
    my ($ctx)=@_;my @args=@{$ctx->args};
    my $channel=@args && $args[0] =~ /^#/ ? shift @args : $ctx->channel;
    my $syntax='Syntax: randomquote [#channel] [status | every 60m | default]; 15m..7d, bare numbers are minutes.';
    return $ctx->reply_private($syntax) unless eval {Mediabot::RandomQuote::State::_channel($channel);1};
    my $operation=@args ? lc shift @args : 'status';
    my $interval;
    if ($operation eq 'every') {$interval=_duration(shift @args)}
    elsif ($operation eq 'default') {$interval=0}
    elsif ($operation ne 'status') {$interval=_duration($operation);$operation='every'}
    return $ctx->reply_private($syntax) if @args || ($operation eq 'every' && !defined $interval);
    my $user=$ctx->require_auth or return;
    unless (eval {$user->has_level('Administrator')}
        || checkUserChannelLevel($ctx->bot,$ctx->message,$channel,$user->id,450)) {
        return $ctx->reply_private('RandomQuote requires Administrator or channel level 450 on the target channel.');
    }
    my ($info,$status,$runtime);
    my $ok=eval {
        $runtime=_runtime($ctx);$info=$runtime->channel_status($channel);
        if ($info) {
            my $default=$runtime->default_interval;
            $status=$operation eq 'status' ? $runtime->{state}->status($channel,$default)
                : $runtime->{state}->configure($channel,$interval,$default);
        }
        1;
    };
    unless ($ok) {
        my $err=$@;eval {$ctx->bot->{logger}->log(1,'RandomQuote command failed: '.$err)};
        return $ctx->reply_private('RandomQuote operation failed; settings were not confirmed.');
    }
    return $ctx->reply_private("Channel $channel is not registered to Mediabot.") unless $info;
    my $enabled=$info->{enabled} ? '+RandomQuote on' : '+RandomQuote off';
    my $frequency=int($status->{interval}/60);my $wait=int(($status->{wait}+59)/60);
    my $source=$status->{custom} ? 'channel setting' : 'default';
    my $schedule=$info->{enabled} && defined($runtime->_joined($channel))
        ? "next attempt in ${wait}m" : 'waiting for +RandomQuote and bot JOIN';
    return $ctx->reply_private("RandomQuote on $channel: $enabled; every ${frequency}m ($source); "
        . "$info->{quotes} quote(s); $schedule. Use chanset $channel +RandomQuote / -RandomQuote to enable / pause.");
}
1;
