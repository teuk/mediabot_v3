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
    package MB704C975::Fetcher;
    sub new { bless { callbacks => [] }, shift }
    sub fetch { my ($s,%a)=@_; push @{ $s->{callbacks} }, $a{on_done}; 1 }
    sub complete { my ($s,$i,$r)=@_; $s->{callbacks}[$i]->($r) }
}
{
    package MB704C975::Ctx;
    sub new { my ($c,%a)=@_; bless \%a,$c }
    sub bot { $_[0]{bot} } sub channel { $_[0]{channel} } sub nick { $_[0]{nick} }
}

return sub {
    my ($assert) = @_;
    my (@notices, @privmsgs);
    my $now = 1000;
    my $bot = { vdm_enabled => 1, connected => 1, channels => { '#test' => {}, '#other' => {} } };
    my $fetcher = MB704C975::Fetcher->new;
    my $runtime = Mediabot::VDM::Runtime->new(
        bot => $bot, fetcher => $fetcher, now_cb => sub { $now }, max_recent => 8,
        chanset_cb => sub { $_[0]{vdm_enabled} ? 1 : 0 },
        connected_cb => sub { $_[0]{connected} ? 1 : 0 },
        joined_cb => sub { exists $_[0]{channels}{lc $_[1]} ? 1 : 0 },
        notice_cb => sub { my ($b,$n,$m)=@_; push @notices,[$n,$m]; 1 },
        send_cb => sub { my ($b,$c,$m)=@_; push @privmsgs,[$c,$m]; 1 },
    );
    my $ctx = MB704C975::Ctx->new(bot=>$bot, channel=>'#test', nick=>'Alice');
    my $items = [
        { id => '1', story => q{Aujourd'hui, première anecdote. VDM} },
        { id => '2', story => q{Aujourd'hui, deuxième anecdote. VDM} },
    ];

    $runtime->request_manual($ctx);
    $fetcher->complete(0, { ok=>1, items=>$items });
    $assert->like($privmsgs[-1][1], qr/\[1\]/,
        'mb704-975: first request selects first valid feed item');

    $now += 1;
    $runtime->request_manual($ctx);
    $fetcher->complete(1, { ok=>1, items=>$items });
    $assert->like($privmsgs[-1][1], qr/\[2\]/,
        'mb704-975: recently emitted id is skipped in favor of next fresh item');

    my $sent_before = scalar @privmsgs;
    $now += 1;
    $runtime->request_manual($ctx);
    $fetcher->complete(2, { ok=>1, items=>$items });
    $assert->is(scalar(@privmsgs), $sent_before,
        'mb704-975: all-recent feed emits no duplicate inside repeat window');
    $assert->like($notices[-1][1], qr/No fresh VDM/,
        'mb704-975: all-recent feed reports a bounded no-fresh result privately');

    $now = 1121;
    $runtime->request_manual($ctx);
    $fetcher->complete(3, { ok=>1, items=>$items });
    $assert->like($privmsgs[-1][1], qr/\[1\]/,
        'mb704-975: id becomes eligible again after historical 120-second window');

    my $ctx_other = MB704C975::Ctx->new(bot=>$bot, channel=>'#other', nick=>'Bob');
    $now = 1122;
    $runtime->request_manual($ctx_other);
    $fetcher->complete(4, { ok=>1, items=>$items });
    $assert->like($privmsgs[-1][1], qr/\[1\]/,
        'mb704-975: anti-repeat state is scoped independently per channel');
};
