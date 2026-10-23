# t/cases/218_usercommands_poll_deadline.t
# =============================================================================
# Verify mbPoll_ctx sets a deadline and mbVote_ctx checks it (B7/fix).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_218 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_218(File::Spec->catfile('.', 'Mediabot', 'CommunityState.pm'));

    $assert->like($src, qr/deadline.*time\(\).*\+/,
        'mbPoll_ctx sets a deadline based on time()');

    $assert->like($src, qr/Poll expired/,
        'mbVote_ctx handles expired poll');

    $assert->like($src, qr/sub mbPoll_ctx/,
        'mbPoll_ctx sub exists');

    $assert->like($src, qr/sub mbVote_ctx/,
        'mbVote_ctx sub exists');

    $assert->like($src, qr/sub mbPollResult_ctx/,
        'mbPollResult_ctx sub exists');

    $assert->like($src, qr/sub mbPollStop_ctx/,
        'mbPollStop_ctx sub exists');


    # MB927: actual poll handlers and Context with a private child-only clock.
    require JSON::PP;
    my $probe=<<'MB927_NATIVE';
use strict;
use warnings;
use utf8;
BEGIN {$MB927::Clock::now=1000;*CORE::GLOBAL::time=sub () {$MB927::Clock::now}}
use JSON::PP;
use Mediabot::CommunityState;
use Mediabot::UserCommands;
use Mediabot::Context;
{
    package MB927::Principal;
    sub is_authenticated {1}
    sub has_level {$_[1] eq 'Master'}
    package MB927::Metrics;
    sub inc {$_[0]{counters}{$_[1]}++;1}
    sub set {$_[0]{gauges}{$_[1]}=$_[2];1}
}
sub copy {JSON::PP::decode_json(JSON::PP->new->utf8->encode($_[0]))}
sub context {
    my ($bot,$nick,$channel,$command,$args)=@_;
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>$nick,channel=>$channel,
        command=>$command,args=>$args//[]);
    $ctx->{user}=bless({},'MB927::Principal');$ctx->{_user_fetched}=1;
    return $ctx;
}
sub run {
    my (%a)=@_;
    $MB927::Clock::now=1000;
    my $bot={_polls=>{},metrics=>bless({counters=>{},gauges=>{}},'MB927::Metrics')};
    my (@wire,@audit,@warnings);
    my $throw=0;
    no warnings qw(redefine once);
    my $send=sub {
        my ($b,$channel,$text)=@_;
        push @wire,['PRIVMSG',$channel,$text];
        die "private poll output refusal\n" if $throw;
        return 1;
    };
    local *Mediabot::UserCommands::botPrivmsg=$send;
    local *Mediabot::Helpers::botPrivmsg=$send;
    local *Mediabot::UserCommands::botNotice=sub {push @wire,['NOTICE',$_[1],$_[2]];1};
    local *Mediabot::UserCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my $prefix=$a{entry} eq 'module' ? 'Mediabot::CommunityState::' : 'Mediabot::UserCommands::';
    my $handler=sub {
        my ($name,$nick,$channel,$args)=@_;
        no strict 'refs';
        return &{$prefix.$name}(context($bot,$nick,$channel,$name,$args));
    };
    my $raw=($a{weighted}?'weighted ':'').'10 thé ou café ? | thé:2 | café:1';
    $raw='10 thé ou café ? | thé | café' unless $a{weighted};
    unless ($a{kind} && $a{kind} eq 'unvote_none') {
        $handler->('mbPoll_ctx','Creator','#test',[$raw]);
        $handler->('mbVote_ctx','Alice','#test',[1]);
        $handler->('mbVote_ctx','Bob','#test',[2]);
        $handler->('mbVote_ctx','Charlie','#test',[1]);
    }
    $handler->('mbPoll_ctx','Creator','#other',['60 another poll | one | two']);
    $handler->('mbVote_ctx','Other','#other',[2]);
    my $kind=$a{kind}//'expired_unvote';
    if ($kind eq 'unvote_closed') {
        $MB927::Clock::now=1009;
        $handler->('mbPollStop_ctx','Creator','#test',[]);
    }
    if ($kind eq 'unvote_after_extend_at') {
        $MB927::Clock::now=1011;
        $handler->('mbPollExtend_ctx','Creator','#test',[10]);
    }
    my $now=defined($a{now})?$a{now}
        :$kind eq 'unvote_before' || $kind eq 'vote_before' || $kind eq 'unvote_absent_vote'?1009
        :$kind eq 'unvote_at' || $kind eq 'vote_at'?1010
        :$kind eq 'unvote_after_extend_at'?1021:1011;
    $MB927::Clock::now=$now;
    @wire=();@audit=();
    my $before=copy($bot->{_polls});
    my $metric_before=copy({%{$bot->{metrics}}});
    my $nick=$a{no_vote} || $kind eq 'unvote_absent_vote'?'Nobody':'Alice';
    my $method=$kind=~/^vote_/ ? 'mbVote_ctx':'mbUnvote_ctx';
    $throw=1 if $kind eq 'vote_expired_output_throw';
    my $result;my $ok=eval {$result=$handler->($method,$nick,'#test',[2]);1};
    my $error=$ok?'':"$@";
    $throw=0;
    my $after=copy($bot->{_polls});
    my $wire=copy(\@wire);my $audit=copy(\@audit);
    @wire=();@audit=();
    $handler->('mbPollResult_ctx','Reader','#test',[]) if exists($bot->{_polls}{'#test'});
    return {before=>$before,after=>$after,return=>$result,error=>$error,
        wire=>$wire,audit=>$audit,result_wire=>copy(\@wire),result_audit=>copy(\@audit),
        metrics_before=>$metric_before,metrics_after=>copy({%{$bot->{metrics}}}),warnings=>\@warnings};
}
my %out;
for my $entry (qw(module facade)) {
    for my $weighted (0,1) {
        for my $no_vote (0,1) {
            for my $now (1011,1600) {
                $out{expired}{$entry}{$weighted}{$no_vote}{$now}
                    =run(entry=>$entry,weighted=>$weighted,no_vote=>$no_vote,now=>$now);
            }
        }
        for my $kind (qw(unvote_before unvote_at unvote_absent_vote unvote_closed
                unvote_none unvote_after_extend_at vote_before vote_at vote_expired
                vote_expired_output_throw)) {
            $out{nominal}{$entry}{$weighted}{$kind}
                =run(entry=>$entry,weighted=>$weighted,kind=>$kind);
        }
    }
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB927_NATIVE
    open my $child,'-|',$^X,'-I.','-It/lib','-e',$probe
        or do {$assert->ok(0,"MB927 native child could not start: $!");return};
    my $raw=do {local $/;<$child>};close $child;
    my $rc=$?;my $data=eval {JSON::PP::decode_json($raw)};
    $assert->ok($rc==0 && ref($data) eq 'HASH',
        'MB927 native poll probe completes and returns JSON');
    return unless $rc==0 && ref($data) eq 'HASH';
    my $json=JSON::PP->new->canonical;
    my $same=sub {$json->encode($_[0]) eq $json->encode($_[1])};
    my $clone=sub {JSON::PP->new->decode($json->encode($_[0]))};
    my $expiry=[['PRIVMSG','#test','Poll expired. Use !pollresult to see results.']];
    my @bad;my $count=0;
    for my $entry (qw(module facade)) {
        for my $weighted (0,1) {
            for my $no_vote (0,1) {
                for my $now (1011,1600) {
                    my $x=$data->{expired}{$entry}{$weighted}{$no_vote}{$now};
                    my $wanted=$clone->($x->{before});$wanted->{'#test'}{active}=0;
                    push @bad,"$entry/$weighted/$no_vote/$now" unless
                        $same->($x->{after},$wanted) && $same->($x->{wire},$expiry)
                        && !defined($x->{return}) && !$x->{error} && !@{$x->{warnings}}
                        && !@{$x->{audit}} && $same->($x->{metrics_before},$x->{metrics_after});
                    $count++;
                }
            }
        }
    }
    $assert->is($json->encode([$count,\@bad]),$json->encode([16,[]]),
        'MB927 expired withdrawals preserve every ballot and other channel, close once and keep expiry metrics');
    @bad=();
    for my $entry (qw(module facade)) {
        for my $weighted (0,1) {
            for my $no_vote (0,1) {
                for my $now (1011,1600) {
                    my $x=$data->{expired}{$entry}{$weighted}{$no_vote}{$now};
                    my $label="th\x{e9}";my $question="th\x{e9} ou caf\x{e9} ?";
                    my $want='Closed poll'.($weighted?' [weighted]':'')
                        .": \"$question\" (3 vote(s))  Winner: $label "
                        .($weighted?'(80% weighted)':'(67%)');
                    push @bad,"$entry/$weighted/$no_vote/$now" unless
                        @{$x->{result_wire}}==3
                        && $same->($x->{result_wire}[0],['PRIVMSG','#test',$want]);
                }
            }
        }
    }
    $assert->is($json->encode(\@bad),'[]',
        'MB927 real result handlers retain the closed winner and weighted score after rejected withdrawal');
    @bad=();$count=0;
    for my $entry (qw(module facade)) {
        for my $weighted (0,1) {
            for my $kind (qw(unvote_before unvote_at unvote_absent_vote unvote_closed unvote_none
                    unvote_after_extend_at vote_before vote_at vote_expired vote_expired_output_throw)) {
                my $x=$data->{nominal}{$entry}{$weighted}{$kind};
                my $state=$clone->($x->{before});
                my $metrics=$clone->($x->{metrics_before});
                my ($ret,$error,$wire)=(1,'',undef);
                my $audits=0;
                if ($kind=~/^(unvote_before|unvote_at|unvote_after_extend_at)$/) {
                    delete $state->{'#test'}{votes}{alice};
                    $wire=[['PRIVMSG','#test','Alice cancelled their vote (2 vote(s) remaining).']];
                } elsif ($kind eq 'unvote_absent_vote') {
                    $wire=[['NOTICE','Nobody','You have not voted yet.']];
                } elsif ($kind eq 'unvote_closed' || $kind eq 'unvote_none') {
                    $wire=[['PRIVMSG','#test','No active poll.']];
                } elsif ($kind eq 'vote_before' || $kind eq 'vote_at') {
                    $state->{'#test'}{votes}{alice}=1;
                    $metrics->{counters}{mediabot_poll_votes_total}++;
                    $audits=1;
                } else {
                    $state->{'#test'}{active}=0;$ret=undef;$wire=$expiry;
                    $error="private poll output refusal\n" if $kind eq 'vote_expired_output_throw';
                }
                my $ok=$same->($x->{after},$state) && $same->($x->{metrics_after},$metrics)
                    && $same->($x->{return},$ret) && $x->{error} eq $error
                    && !@{$x->{warnings}} && @{$x->{audit}}==$audits;
                $ok &&= $same->($x->{wire},$wire) if defined($wire);
                if ($kind eq 'vote_before' || $kind eq 'vote_at') {
                    $ok &&= @{$x->{wire}}==2
                        && $x->{wire}[0][2] eq "Alice voted for \"caf\x{e9}\" (3 vote(s) cast)";
                }
                push @bad,"$entry/$weighted/$kind" unless $ok;
                $count++;
            }
        }
    }
    $assert->is($json->encode([$count,\@bad]),$json->encode([40,[]]),
        'MB927 nominal withdrawals, exact deadline, explicit extension and existing vote expiry/throw contracts stay intact');
};
