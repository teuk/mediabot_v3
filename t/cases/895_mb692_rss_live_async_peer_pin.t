# t/cases/895_mb692_rss_live_async_peer_pin.t
# mb692 — live DEV caught silent async RSS output + peer-pinning gap.
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use Mediabot::RSS::Fetcher;

sub _slurp_895 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/; return <$fh>;
}

{
    package FakeTiny895;
    sub get {
        my ($self, $url, $args) = @_;
        $self->{seen_url}  = $url;
        $self->{seen_peer} = $args->{peer};
        return { success => 1, status => 200, headers => {}, content => '<rss><channel><title>x</title></channel></rss>' };
    }
}

return sub {
    my ($assert) = @_;

    require Mediabot::CommandAsync;

    my @leaked;
    no warnings qw(redefine once);
    local *Mediabot::botPrivmsg = sub { push @leaked, [ privmsg => $_[2] ]; 1 };
    local *Mediabot::botNotice  = sub { push @leaked, [ notice  => $_[2] ]; 1 };
    local *Mediabot::botAction  = sub { push @leaked, [ action  => $_[2] ]; 1 };

    my $bot = bless {}, 'Mediabot';
    my ($intents, undef, $ok) = Mediabot::CommandAsync::_collect_intents_run(sub {
        $bot->botNotice('nick', 'ctx notice');
        $bot->botPrivmsg('#chan', 'ctx public');
        $bot->botAction('#chan', 'ctx action');
        1;
    });
    $assert->ok($ok, 'mb692-895: bot-method worker path executes');
    $assert->is(scalar(@$intents), 3, 'mb692-895: bot-method replies become intents');
    $assert->is(join(',', map { $_->[0] } @$intents), 'notice,privmsg,action',
        'mb692-895: bot-method intent kinds/order preserved');
    $assert->is(scalar(@leaked), 0, 'mb692-895: no bot-method output leaks from worker');

    $bot->botNotice('nick', 'after');
    $assert->is(scalar(@leaked), 1, 'mb692-895: bot method restored after collection');

    my $fake = bless {}, 'FakeTiny895';
    local *HTTP::Tiny::new = sub { return $fake };
    my $res = Mediabot::RSS::Fetcher::_default_requester(
        'https://feed.example/rss',
        timeout => 3,
        max_size => 1024,
        validated_addresses => ['93.184.216.34'],
    );
    $assert->is($fake->{seen_peer}, '93.184.216.34',
        'mb692-895: HTTP::Tiny connection is pinned to validated peer');
    $assert->is($fake->{seen_url}, 'https://feed.example/rss',
        'mb692-895: original hostname remains in URL for Host/TLS identity');
    $assert->ok($res->{success}, 'mb692-895: pinned requester result returned');

    my $fetch = _slurp_895('Mediabot/RSS/Fetcher.pm');
    $assert->like($fetch, qr/peer\s*=>\s*\$peer/,
        'mb692-895: default requester passes pinned peer to HTTP::Tiny');
    $assert->like($fetch, qr/validated_addresses/,
        'mb692-895: default requester consumes validated address set');

    my $cmd = _slurp_895('Mediabot/RSS/Commands.pm');
    $assert->like($cmd, qr/sub _probe_worker .*?reply_private.*?reply\(/s,
        'mb692-895: probe worker uses Context reply paths captured by CommandAsync');
    $assert->like($cmd, qr/sub _show_worker .*?reply_private.*?reply\(/s,
        'mb692-895: show worker uses Context reply paths captured by CommandAsync');

    my $async = _slurp_895('Mediabot/CommandAsync.pm');
    $assert->like($async, qr/local \*Mediabot::botPrivmsg/,
        'mb692-895: CommandAsync captures bot-method privmsg path');
    $assert->like($async, qr/local \*Mediabot::botNotice/,
        'mb692-895: CommandAsync captures bot-method notice path');
};
