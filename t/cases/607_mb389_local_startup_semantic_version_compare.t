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
use IPC::Open3;
use Symbol qw(gensym);

BEGIN {
    no warnings 'redefine';
    # mb525-B2: fallbacks installed through runtime glob assignments only.
    # Named `sub` declarations inside a stub `package` block are compiled
    # unconditionally and used to overwrite the real modules (notably
    # IO::Async::Timer::Countdown) for every later test in the shared harness.
    no strict 'refs';
    eval { require JSON::MaybeXS; 1 } or do {
        require JSON::PP;
        *{'JSON::MaybeXS::import'} = sub {
            my $caller = caller;
            *{"${caller}::encode_json"} = \&JSON::PP::encode_json;
            *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        };
        $INC{'JSON/MaybeXS.pm'} = __FILE__;
    };

    eval { require Try::Tiny; 1 } or do {
        *{'Try::Tiny::import'} = sub { return 1 };
        $INC{'Try/Tiny.pm'} = __FILE__;
    };

    eval { require IO::Async::Timer::Countdown; 1 } or do {
        *{'IO::Async::Timer::Countdown::new'}   = sub { bless {}, shift };
        *{'IO::Async::Timer::Countdown::start'} = sub { 1 };
        *{'IO::Async::Timer::Countdown::stop'}  = sub { 1 };
        $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
    };

    eval { require IO::Async::Stream; 1 } or do {
        *{'IO::Async::Stream::new'} = sub { bless {}, shift };
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
    my $format = _slurp_mb389(File::Spec->catfile($root, 'Mediabot', 'Version', 'Format.pm'));
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
        $format,
        qr/sub _compare_mediabot_versions\s*\{/,
        'semantic version comparator is present'
    );

    require $helpers_file;

    require Mediabot::Version::Format;

    for my $order (
        [qw(Version::Format)],
        [qw(Version::Format Helpers)],
        [qw(Helpers Version::Format)],
    ) {
        my $code = join('', map { "require Mediabot::$_;\n" } @$order);
        $code .= q{
            my $cold = !exists $INC{'Mediabot/Helpers.pm'};
            Mediabot::Version::Format->import(qw(_usable_local_version _version_parts
                _compare_digit_strings _compare_mediabot_versions getDetailedVersion));
            die 'normalizer failed' unless _usable_local_version(' 3.5 ') eq '3.5';
            my $parts = _version_parts('3.6dev-00020261021_201821');
            die 'parser failed' unless $parts->{major} == 3 && $parts->{minor} == 6
                && $parts->{type} eq 'devel' && $parts->{dev} eq '20261021201821';
            die 'digit comparison failed' unless _compare_digit_strings('999', '1000') < 0;
            die 'release ordering failed' unless _compare_mediabot_versions(
                '3.5', '3.5dev-20991231_235959') > 0;
            my @d = getDetailedVersion(undef, '3.5');
            die 'detail tuple failed' unless @d == 4 && $d[0] == 3
                && $d[1] == 5 && $d[2] eq 'stable' && !defined $d[3];
            die 'unexpected dependency load' if $cold && (
                exists $INC{'Mediabot/Helpers.pm'} || exists $INC{'HTTP/Tiny.pm'}
                || exists $INC{'DBI.pm'});
            require Mediabot::Helpers;
            die 'historical comparator failed' unless
                Mediabot::Helpers::_compare_mediabot_versions('3.5', '3.6dev-1') < 0;
            print 'loaded';
        };
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
        my $stdout = do { local $/; <$out> } // '';
        my $stderr = do { local $/; <$err> } // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
            'pure version functions work in load order: ' . join('/', @$order));
    }
    {
        no warnings 'redefine';
        local *Mediabot::Helpers::_usable_local_version = sub { '8.1' };
        my $parts = Mediabot::Version::Format::_version_parts('legacy input');
        $assert->ok($parts && $parts->{major} == 8 && $parts->{minor} == 1
                && $parts->{type} eq 'stable',
            'canonical parser keeps the call-time legacy normalizer');
    }
    {
        no warnings 'redefine';
        my @seen;
        local *Mediabot::Helpers::_version_parts = sub {
            push @seen, $_[0];
            return {major=>8, minor=>1, stage=>0, type=>'devel',
                dev=>$_[0] eq 'newer' ? '200' : '100'};
        };
        my @detail = Mediabot::Version::Format::getDetailedVersion(undef, 'detail');
        my $cmp = Mediabot::Version::Format::_compare_mediabot_versions('older', 'newer');
        $assert->ok(join('|', @detail) eq '8|1|devel|100' && $cmp < 0
                && join('|', @seen) eq 'detail|older|newer',
            'canonical details and comparison keep the legacy parser and argument order');
    }
    {
        no warnings 'redefine';
        my @seen;
        local *Mediabot::Helpers::_compare_digit_strings = sub {
            @seen = @_; return -17;
        };
        my $cmp = Mediabot::Version::Format::_compare_mediabot_versions(
            '3.6dev-001_2', '3.6dev-001_3');
        $assert->ok($cmp == -17 && join('|', @seen) eq '12|13',
            'canonical comparison keeps the legacy digit comparator and its exact return');
    }

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
