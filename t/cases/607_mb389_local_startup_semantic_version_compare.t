# t/cases/607_mb389_local_startup_semantic_version_compare.t
# =============================================================================
# MB389: startup must be local-only and remote versions must be compared by
# release semantics rather than by simple string inequality.
# =============================================================================

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Spec;
use File::Temp qw(tempdir);

BEGIN {
    no warnings 'redefine';
    eval { require JSON::MaybeXS; 1 } or do {
        require JSON::PP;
        package JSON::MaybeXS;
        sub import {
            my $caller = caller;
            no strict 'refs';
            *{"${caller}::encode_json"} = \&JSON::PP::encode_json;
            *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        }
        $INC{'JSON/MaybeXS.pm'} = __FILE__;
    };

    eval { require Try::Tiny; 1 } or do {
        package Try::Tiny;
        sub import { return 1 }
        $INC{'Try/Tiny.pm'} = __FILE__;
    };

    eval { require IO::Async::Timer::Countdown; 1 } or do {
        package IO::Async::Timer::Countdown;
        sub new   { bless {}, shift }
        sub start { 1 }
        sub stop  { 1 }
        $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
    };

    eval { require IO::Async::Stream; 1 } or do {
        package IO::Async::Stream;
        sub new { bless {}, shift }
        $INC{'IO/Async/Stream.pm'} = __FILE__;
    };
}

sub _slurp_mb389 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $root = abs_path('.');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    my $main_file    = File::Spec->catfile($root, 'mediabot.pl');
    my $version_file = File::Spec->catfile($root, 'VERSION');

    my $helpers = _slurp_mb389($helpers_file);
    my $main    = _slurp_mb389($main_file);
    my $expected = _slurp_mb389($version_file);
    $expected =~ s/\s+\z//;

    $assert->like(
        $main,
        qr/\$MAIN_PROG_VERSION\s*=\s*\$mediabot->getLocalVersion\(\)/,
        'startup uses the local-only version helper'
    );

    $assert->unlike(
        $main,
        qr/\$mediabot->getVersion\(\)/,
        'startup contains no synchronous remote version lookup'
    );

    $assert->like(
        $helpers,
        qr/sub _compare_mediabot_versions\s*\{/,
        'semantic version comparator is present'
    );

    require $helpers_file;

    {
        package MB389::Logger;
        sub new { bless { lines => [] }, shift }
        sub log { push @{ $_[0]->{lines} }, $_[2]; 1 }
    }

    {
        package MB389::Conf;
        sub get { return 'Mediabot' }
    }

    {
        package MB389::Bot;
        sub getLoop { return undef }
    }

    {
        package MB389::Context;
        sub new { bless { bot => $_[1], replies => [] }, $_[0] }
        sub bot { $_[0]->{bot} }
        sub message { return bless {}, 'MB389::Message' }
        sub reply { push @{ $_[0]->{replies} }, $_[1]; 1 }
    }

    my $bot = bless {
        logger            => MB389::Logger->new,
        conf              => bless({}, 'MB389::Conf'),
        main_prog_version => 'cached-version',
    }, 'MB389::Bot';

    my $http_called = 0;
    my $cwd = getcwd();
    my $foreign = tempdir(CLEANUP => 1);
    my $local;
    {
        no warnings 'redefine';
        local *HTTP::Tiny::new = sub { $http_called++; die 'network must not run' };
        chdir $foreign or die "cannot chdir to $foreign: $!";
        $local = Mediabot::Helpers::getLocalVersion($bot);
        chdir $cwd or die "cannot restore cwd $cwd: $!";
    }

    $assert->is($local, $expected, 'local version is read from the source tree');
    $assert->is($http_called, 0, 'local startup helper performs no HTTP access');

    my @comparisons = (
        ['3.2dev-20260702_100000', '3.2dev-20260702_100000',  0, 'equal dev builds'],
        ['3.2dev-20260702_100000', '3.2dev-20260702_110000', -1, 'older dev build'],
        ['3.2dev-20260702_120000', '3.2dev-20260702_110000',  1, 'newer local dev build'],
        ['3.3dev-20260702_120000', '3.3',                    -1, 'stable beats same-base dev'],
        ['3.3',                    '3.3dev-20260702_120000',  1, 'local stable beats same-base dev'],
        ['3.3',                    '3.2dev-20991231_235959',  1, 'higher stable base beats older dev base'],
        ['4.0dev-20260101_000000', '3.9',                     1, 'higher major dev beats lower stable'],
    );

    for my $case (@comparisons) {
        my ($left, $right, $want, $label) = @$case;
        $assert->is(
            Mediabot::Helpers::_compare_mediabot_versions($left, $right),
            $want,
            $label,
        );
    }

    $assert->ok(
        !defined Mediabot::Helpers::_compare_mediabot_versions('banana', '3.3'),
        'unknown local format is not ordered'
    );

    my $run_version_command = sub {
        my ($local_value, $remote_value) = @_;
        $bot->{main_prog_version} = $local_value;
        my $ctx = MB389::Context->new($bot);

        no warnings 'redefine';
        local *Mediabot::Helpers::getVersion_async = sub {
            my ($self, $callback) = @_;
            $callback->($local_value, $remote_value);
            return 1;
        };
        local *Mediabot::Helpers::logBot = sub { 1 };
        Mediabot::Helpers::versionCheck($ctx);
        return [ @{ $ctx->{replies} } ];
    };

    my $older = $run_version_command->(
        '3.2dev-20260702_100000',
        '3.2dev-20260702_110000',
    );
    $assert->is(
        $older->[0],
        'Mediabot version: 3.2dev-20260702_100000',
        'older local build replies with local identity immediately'
    );
    $assert->is(
        $older->[1],
        'Mediabot update available: 3.2dev-20260702_110000 (local: 3.2dev-20260702_100000)',
        'older local build receives an asynchronous update follow-up'
    );

    my $newer = $run_version_command->('3.3', '3.2dev-20991231_235959');
    $assert->is(
        $newer->[0],
        'Mediabot version: 3.3',
        'newer stable build replies with local identity immediately'
    );
    $assert->is(
        $newer->[1],
        'Mediabot local build newer than repository: 3.3 (repository: 3.2dev-20991231_235959)',
        'newer stable local build is not reported as outdated'
    );

    my $equal = $run_version_command->('3.3', '3.3');
    $assert->is(
        scalar(@$equal),
        1,
        'equal versions need no redundant asynchronous follow-up'
    );
    $assert->is(
        $equal->[0],
        'Mediabot version: 3.3',
        'equal versions keep the immediate local reply'
    );
};
