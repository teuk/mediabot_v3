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
    package MB704C::Ctx;
    sub new { my ($class, %a) = @_; bless \%a, $class }
    sub bot { $_[0]{bot} }
    sub channel { $_[0]{channel} }
    sub nick { $_[0]{nick} }
}

{
    package MB704C::Fetcher;
    sub new { bless { calls => [], accept => 1 }, shift }
    sub fetch {
        my ($self, %args) = @_;
        push @{ $self->{calls} }, $args{on_done};
        return $self->{accept};
    }
    sub complete {
        my ($self, $idx, $res) = @_;
        $self->{calls}[$idx]->($res);
    }
}

return sub {
    my ($assert) = @_;

    my (@notices, @privmsgs, @logs);
    my $bot = { vdm_enabled => 0, connected => 1, channels => { '#test' => {} } };
    my $fetcher = MB704C::Fetcher->new;
    my $runtime = Mediabot::VDM::Runtime->new(
        bot => $bot,
        fetcher => $fetcher,
        now_cb => sub { 1000 },
        chanset_cb => sub { $_[0]{vdm_enabled} ? 1 : 0 },
        connected_cb => sub { $_[0]{connected} ? 1 : 0 },
        joined_cb => sub { exists $_[0]{channels}{lc $_[1]} ? 1 : 0 },
        notice_cb => sub { my ($b,$n,$m)=@_; push @notices,[$n,$m]; 1 },
        send_cb => sub { my ($b,$c,$m)=@_; push @privmsgs,[$c,$m]; 1 },
    );
    $runtime->{bot}{logger} = bless { sink => \@logs }, 'MB704C::Logger';
    no warnings 'once';
    *MB704C::Logger::log = sub { my ($self,$level,$text)=@_; push @{ $self->{sink} },[$level,$text]; 1 };

    my $ctx = MB704C::Ctx->new(bot => $bot, channel => '#test', nick => 'Alice');

    $assert->ok($runtime->request_manual($ctx),
        'mb704-974: disabled manual command is handled without falling through');
    $assert->is(scalar(@{ $fetcher->{calls} }), 0,
        'mb704-974: -VDM blocks the network request before worker start');
    $assert->like($notices[-1][1], qr/chanset -VDM/,
        'mb704-974: disabled channel receives an explicit private refusal');

    $bot->{vdm_enabled} = 1;
    $assert->ok($runtime->request_manual($ctx),
        'mb704-974: +VDM starts the asynchronous manual path');
    $assert->is(scalar(@{ $fetcher->{calls} }), 1,
        'mb704-974: one source request is queued');
    $assert->ok($runtime->channel_pending('#TEST'),
        'mb704-974: pending state is case-canonical per channel');

    $fetcher->complete(0, {
        ok => 1,
        items => [ { id => '513869', story => q{Aujourd'hui, même mon test a une vie de merde. VDM} } ],
    });

    $assert->ok(!$runtime->channel_pending('#test'),
        'mb704-974: completion clears channel pending state');
    $assert->is(scalar(@privmsgs), 1,
        'mb704-974: successful completion emits exactly one public line');
    $assert->is($privmsgs[0][0], '#test',
        'mb704-974: VDM is emitted to the requesting channel');
    $assert->like($privmsgs[0][1], qr/\[513869\]/,
        'mb704-974: formatted VDM keeps its numeric story id');
    $assert->like($privmsgs[0][1], qr/VDM\x0f\z/,
        'mb704-974: formatted story retains VDM marker and final IRC reset');

    my $log_text = join("\n", map { $_->[1] } @logs);
    $assert->like($log_text, qr/\[VDM\].*action=sent.*story_id=513869/s,
        'mb704-974: manual delivery produces metadata diagnostics');
    $assert->unlike($log_text, qr/vie de merde/,
        'mb704-974: VDM diagnostics never log source story text themselves');
};
