use strict;
use warnings;
use Test::More;
use Mediabot::Hailo::ReplyQueue;
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
sub put {
    my ($q,$payload,%opts)=@_;
    return $q->enqueue(channel=>'#test',payload=>$payload,on_ready=>sub {1},%opts);
}
{
    my $now=0; my @expired;
    my $q=Mediabot::Hailo::ReplyQueue->new(now_cb=>sub {$now},ttl_seconds=>5);
    put($q,'old',on_expire=>sub {push @expired,$_[0]{payload}});
    $now=4;put($q,'fresh');
    my @seen;
    my $selected=$q->take_next(sub {
        my ($e)=@_;push @seen,$e->{payload};
        if ($e->{payload} eq 'old') {$now=5;$q->stats;return 1}
        return 0;
    });
    ok(!defined($selected),'an expired selection does not remove the fresh successor');
    is_deeply(\@seen,[qw(old fresh)],'surviving candidate is tested independently');
    is_deeply(\@expired,['old'],'expired entry reported exactly once');
    is($q->stats->{dropped_expired},1,'expiry counter retained');
    is(($q->take_next // {})->{payload},'fresh','rejected fresh entry remains queued');
}
{
    my $q=Mediabot::Hailo::ReplyQueue->new(now_cb=>sub {0});
    put($q,'first');put($q,'second');
    my (@seen,$nested);
    my $outer=$q->take_next(sub {
        my ($e)=@_;push @seen,$e->{payload};
        if ($e->{payload} eq 'first') {$nested=$q->take_next;return 1}
        return 0;
    });
    is($nested->{payload},'first','nested consumer receives first entry');
    ok(!defined($outer),'outer selection cannot consume a different entry');
    is_deeply(\@seen,[qw(first second)],'next live entry must pass its own predicate');
    is(($q->take_next // {})->{payload},'second','second entry survives rejected outer selection');
}
{
    my $q=Mediabot::Hailo::ReplyQueue->new(now_cb=>sub {0});
    put($q,'first');put($q,'second');
    my @seen;
    my $outer=$q->take_next(sub {
        my ($e)=@_;push @seen,$e->{payload};
        if ($e->{payload} eq 'first') {
            $q->take_next;$q->take_next;put($q,'new');return 0;
        }
        return 1;
    });
    ok(!defined($outer),'new entries wait for the next selection');
    is_deeply(\@seen,['first'],'removed snapshot entries are never passed to the predicate');
    is(($q->take_next // {})->{payload},'new','new entry remains available');
}
{
    my $q=Mediabot::Hailo::ReplyQueue->new(now_cb=>sub {0});
    put($q,'first');put($q,'second');put($q,'third');
    my $outer=$q->take_next(sub {
        return 0 if $_[0]{payload} eq 'first';
        if ($_[0]{payload} eq 'second') {$q->take_next;return 1}
        return 0;
    });
    is($outer->{payload},'second','selected entry is found after an earlier entry shifts its index');
    is(($q->take_next // {})->{payload},'third','unselected successor survives');
}
{
    my $q=Mediabot::Hailo::ReplyQueue->new(now_cb=>sub {0});
    put($q,'first');put($q,'second');
    is($q->take_next(sub {die "predicate failure\n" if $_[0]{payload} eq 'first';1})->{payload},
       'second','predicate exceptions still skip that candidate');
    is(($q->take_next // {})->{payload},'first','failed candidate remains queued');
    ok(!defined($q->take_next(sub {1})),'empty filtered queue returns undef');
}
is_deeply(\@warnings, [], 'queue mutation emits no warnings');
done_testing;
