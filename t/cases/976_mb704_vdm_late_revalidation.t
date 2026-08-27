use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}
use Mediabot::VDM::Runtime;

{
    package MB704C976::Fetcher;
    sub new { bless { callbacks => [] }, shift }
    sub fetch { my ($s,%a)=@_; push @{ $s->{callbacks} }, $a{on_done}; 1 }
    sub complete { my ($s,$i,$r)=@_; $s->{callbacks}[$i]->($r) }
}
{
    package MB704C976::Ctx;
    sub new { my ($c,%a)=@_; bless \%a,$c }
    sub bot { $_[0]{bot} } sub channel { $_[0]{channel} } sub nick { $_[0]{nick} }
}

return sub {
    my ($assert) = @_;
    my @privmsgs;
    my $bot = { vdm_enabled => 1, connected => 1, channels => { '#test' => {} } };
    my $fetcher = MB704C976::Fetcher->new;
    my $runtime = Mediabot::VDM::Runtime->new(
        bot=>$bot, fetcher=>$fetcher, now_cb=>sub { 1000 },
        chanset_cb => sub { $_[0]{vdm_enabled} ? 1 : 0 },
        connected_cb => sub { $_[0]{connected} ? 1 : 0 },
        joined_cb => sub { exists $_[0]{channels}{lc $_[1]} ? 1 : 0 },
        notice_cb => sub { 1 },
        send_cb => sub { my ($b,$c,$m)=@_; push @privmsgs,[$c,$m]; 1 },
    );
    my $ctx = MB704C976::Ctx->new(bot=>$bot, channel=>'#test', nick=>'Alice');
    my $result = { ok=>1, items=>[ { id=>'9', story=>q{Aujourd'hui, réponse tardive. VDM} } ] };

    $runtime->request_manual($ctx);
    $bot->{vdm_enabled} = 0;
    $fetcher->complete(0, $result);
    $assert->is(scalar(@privmsgs), 0,
        'mb704-976: removing +VDM while fetch is inflight revokes late delivery');

    $bot->{vdm_enabled} = 1;
    $runtime->request_manual($ctx);
    delete $bot->{channels}{'#test'};
    $fetcher->complete(1, $result);
    $assert->is(scalar(@privmsgs), 0,
        'mb704-976: parting channel while fetch is inflight revokes late delivery');

    $bot->{channels}{'#test'} = {};
    $runtime->request_manual($ctx);
    $bot->{connected} = 0;
    $fetcher->complete(2, $result);
    $assert->is(scalar(@privmsgs), 0,
        'mb704-976: IRC disconnect while fetch is inflight revokes late delivery');

    $bot->{connected} = 1;
    $runtime->request_manual($ctx);
    $assert->ok($runtime->channel_pending('#test'),
        'mb704-976: current request has generation-like pending ownership');
    $runtime->clear_channel('#TEST');
    $fetcher->complete(3, $result);
    $assert->is(scalar(@privmsgs), 0,
        'mb704-976: explicit channel cleanup makes late callback stale');
};
