# MB720-E — reloadable Hailo nick exclusions and self-output isolation.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";

    # Minimal compile-time stubs for optional runtime dependencies absent from
    # the isolated test image. None of them is exercised by this identity test.
    package URI::Escape;
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::uri_escape"} = sub { $_[0] };
    }
    $INC{'URI/Escape.pm'} = __FILE__;

    package JSON::MaybeXS;
    sub import { }
    $INC{'JSON/MaybeXS.pm'} = __FILE__;

    package Try::Tiny;
    sub import { }
    $INC{'Try/Tiny.pm'} = __FILE__;

    package IO::Async::Timer::Countdown;
    sub import { }
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;

    package IO::Async::Stream;
    sub import { }
    $INC{'IO/Async/Stream.pm'} = __FILE__;

    package Hailo;
    sub new { bless {}, shift }
    $INC{'Hailo.pm'} = __FILE__;

    package main;
}

use File::Spec;
use Mediabot::Hailo ();

{
    package MB720E::Conf;
    sub new { bless { values => $_[1] || {} }, $_[0] }
    sub get { $_[0]{values}{$_[1]} }
    sub set { $_[0]{values}{$_[1]} = $_[2] }
}

{
    package MB720E::IRC;
    sub new { bless { nick => $_[1] }, $_[0] }
    sub nick_folded { $_[0]{nick} }
}

{
    package MB720E::DBH;
    sub new { bless { rows => $_[1] || {}, prepare_calls => 0 }, $_[0] }
    sub prepare {
        my ($self) = @_;
        $self->{prepare_calls}++;
        return bless { dbh => $self, nick => undef }, 'MB720E::STH';
    }
}

{
    package MB720E::STH;
    sub execute { $_[0]{nick} = $_[1]; 1 }
    sub fetchrow_hashref {
        my ($self) = @_;
        my $key = lc($self->{nick} // '');
        return $self->{dbh}{rows}{$key} ? { excluded => 1 } : undef;
    }
    sub finish { 1 }
}

sub _slurp_1027 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $conf = MB720E::Conf->new({
        'connection.CONN_NICK'       => 'ConfiguredBot',
        'main.BOT_NICKS'             => 'RelayBot, Guard[Bot]',
        'hailo.HAILO_IGNORE_NICKS'   => ' Coin, nick2, Nick[3] ',
    });
    my $dbh = MB720E::DBH->new({ dbnick => 1 });
    my $bot = bless {
        conf => $conf,
        irc  => MB720E::IRC->new('Media[bot]'),
        dbh  => $dbh,
    }, 'MB720E::Bot';

    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'cOiN'),
        'HAILO_IGNORE_NICKS matching is case-insensitive');
    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'nick{3}'),
        'HAILO_IGNORE_NICKS uses the RFC1459 bracket casemap');
    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'guard{bot}'),
        'shared BOT_NICKS entries are also excluded from Hailo');
    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'media{bot}'),
        'the live bot nick is always excluded from Hailo');
    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'configuredbot'),
        'configured connection nick is excluded before IRC is fully available');
    $assert->is($dbh->{prepare_calls}, 0,
        'configuration and self exclusions never require a database query');

    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'DbNick'),
        'historical SQL exclusion remains supported');
    $assert->is($dbh->{prepare_calls}, 1,
        'SQL exclusion is queried only after configuration checks');

    $conf->set('hailo.HAILO_IGNORE_NICKS', '');
    $assert->ok(!Mediabot::Hailo::is_hailo_excluded_nick($bot, 'Coin'),
        'removing a configured nick applies immediately without stale positive cache');
    my $queries_after_removal = $dbh->{prepare_calls};
    $conf->set('hailo.HAILO_IGNORE_NICKS', 'Coin');
    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick($bot, 'COIN'),
        'adding a configured nick overrides a cached SQL miss immediately');
    $assert->is($dbh->{prepare_calls}, $queries_after_removal,
        'config reload path is independent from the SQL cache TTL');

    my $without_db = bless {
        conf => MB720E::Conf->new({
            'hailo.HAILO_IGNORE_NICKS' => 'OfflineBot',
        }),
    }, 'MB720E::Bot';
    $assert->ok(Mediabot::Hailo::is_hailo_excluded_nick(
        $without_db, 'offlinebot'
    ), 'configured exclusions remain authoritative while DB is unavailable');

    my $main = _slurp_1027(File::Spec->catfile('.', 'mediabot.pl'));
    my $sample = _slurp_1027(File::Spec->catfile('.', 'mediabot.sample.conf'));
    my $docs = _slurp_1027(File::Spec->catfile('.', 'docs', 'HAILO_3.5.md'));

    $assert->is(scalar(() = $main =~ /my \$from_hailo_ignored\s*=/g), 1,
        'public ingress computes one shared Hailo identity decision');
    $assert->like($main,
        qr/hailo_observe_public_line\(.*?from_bot\s*=>\s*\$from_hailo_ignored/s,
        'ignored and self nick lines never enter provider context');
    $assert->like($main,
        qr/hailo_record_activity\(\$where\)\s*\n\s*unless \$from_hailo_ignored/,
        'ignored and self nick lines do not influence chatter activity');
    $assert->is(scalar(() = $main =~ /unless \(\$from_hailo_ignored \|\|/g), 3,
        'mention, chatter and ambient learning share the same exclusion gate');
    $assert->like($sample, qr/^HAILO_IGNORE_NICKS=$/m,
        'sample configuration exposes an empty safe default');
    $assert->like($sample,
        qr/HAILO_IGNORE_NICKS=Coin,nick2,nick3/,
        'sample documents the requested comma-separated syntax');
    $assert->like($docs,
        qr/echo-message.*outgoing RSS announcements/s,
        'architecture explicitly excludes echoed RSS output from training');
};
