# t/cases/606_mb388_release_version_identity.t
# =============================================================================
# MB388: release identity must be independent of cwd and must survive failures
# in the asynchronous remote-version worker without becoming "Undefined".
# =============================================================================

use strict;
use warnings;
use Cwd qw(getcwd abs_path);
use File::Spec;
use File::Temp qw(tempdir);

BEGIN {
    # Keep the test runnable in the lightweight audit container. On the real
    # server the actual modules win; these fallbacks are installed only when a
    # dependency is unavailable.
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

sub _slurp_mb388 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $root = abs_path('.');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    my $version_file = File::Spec->catfile($root, 'VERSION');

    my $src = _slurp_mb388($helpers_file);
    my $expected_version = _slurp_mb388($version_file);
    $expected_version =~ s/\s+\z//;

    $assert->like(
        $src,
        qr/my \$HELPERS_SOURCE_FILE = abs_path\(__FILE__\)/,
        'Helpers anchors the source file to an absolute path'
    );

    $assert->like(
        $src,
        qr/my \$LOCAL_VERSION_FILE\s+=\s+File::Spec->catfile\(\$MEDIABOT_ROOT_DIR, 'VERSION'\)/,
        'local VERSION path is derived from the source tree'
    );

    $assert->unlike(
        $src,
        qr/open my \$fh, '<', 'VERSION'/,
        'no cwd-relative VERSION open remains'
    );

    require $helpers_file;

    {
        package MB388::Logger;
        sub new { bless { lines => [] }, shift }
        sub log { push @{ $_[0]->{lines} }, $_[2]; 1 }
    }

    {
        package MB388::Conf;
        sub new { bless {}, shift }
        sub get { return 'Mediabot' }
    }

    {
        package MB388::Bot;
        sub getDetailedVersion {
            shift;
            return Mediabot::Helpers::getDetailedVersion(undef, @_);
        }
        sub getLoop { return undef }
    }

    {
        package MB388::Context;
        sub new { bless { bot => $_[1], replies => [] }, $_[0] }
        sub bot { $_[0]->{bot} }
        sub message { return bless {}, 'MB388::Message' }
        sub reply { push @{ $_[0]->{replies} }, $_[1]; 1 }
    }

    {
        package MB388::HTTP;
        sub get { return { success => 0, status => 503, reason => 'offline' } }
    }

    my $bot = bless {
        logger            => MB388::Logger->new,
        conf              => MB388::Conf->new,
        main_prog_version => '3.2dev-cached',
    }, 'MB388::Bot';

    my $cwd = getcwd();
    my $foreign_cwd = tempdir(CLEANUP => 1);

    my ($local, $remote);
    {
        no warnings 'redefine';
        local *HTTP::Tiny::new = sub { bless {}, 'MB388::HTTP' };
        chdir $foreign_cwd or die "cannot chdir to $foreign_cwd: $!";
        ($local, $remote) = Mediabot::Helpers::getVersion($bot);
        chdir $cwd or die "cannot restore cwd $cwd: $!";
    }

    $assert->is(
        $local,
        $expected_version,
        'getVersion reads the repository VERSION from an unrelated cwd'
    );

    $assert->is(
        $bot->{main_prog_version},
        $expected_version,
        'usable local VERSION refreshes runtime state'
    );

    $bot->{main_prog_version} = '3.2dev-cached';
    my $ctx = MB388::Context->new($bot);

    {
        no warnings 'redefine';
        local *Mediabot::Helpers::getVersion_async = sub {
            my ($self, $callback) = @_;
            $callback->('Undefined', 'Undefined');
            return 1;
        };
        local *Mediabot::Helpers::logBot = sub { 1 };
        Mediabot::Helpers::versionCheck($ctx);
    }

    $assert->is(
        $bot->{main_prog_version},
        '3.2dev-cached',
        'failed async lookup cannot poison cached runtime version'
    );

    $assert->is(
        $ctx->{replies}[0],
        'Mediabot version: 3.2dev-cached',
        'version command replies with cached identity when worker fails'
    );
};
