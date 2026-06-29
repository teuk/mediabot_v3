# t/cases/587_mb368_atomic_config_reload.t
#
# mb368 — .reload/.reloadconf must use the real Mediabot::Conf API, and a
# failed parse must never destroy the last known-good in-memory configuration.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempfile tempdir);
use Scalar::Util qw(refaddr);

BEGIN {
    unshift @INC, "$Bin/../..";

    package Config::Simple;
    our $LAST_OBJECT;

    sub import { }

    sub new {
        my ($class, %args) = @_;
        my $file = $args{filename};
        open my $fh, '<', $file or return;
        my %vars;
        while (my $line = <$fh>) {
            chomp $line;
            $line =~ s/\r\z//;
            return if $line eq '!!PARSE-FAIL!!';
            next if $line =~ /^\s*(?:#|;|$)/;
            my ($key, $value) = split /=/, $line, 2;
            return unless defined $value;
            $key   =~ s/^\s+|\s+$//g;
            $value =~ s/^\s+|\s+$//g;
            $vars{$key} = $value;
        }
        close $fh;
        $LAST_OBJECT = bless { file => $file, vars => \%vars }, $class;
        return $LAST_OBJECT;
    }

    sub vars { return %{ $_[0]{vars} } }
    sub param {
        my ($self, $key, $value) = @_;
        $self->{vars}{$key} = $value if @_ >= 3;
        return $self->{vars}{$key};
    }
    sub write { return 1 }

    $INC{'Config/Simple.pm'} = __FILE__;

    for my $module (
        ['IO/Async/Listener.pm',        'IO::Async::Listener'],
        ['IO/Async/Stream.pm',          'IO::Async::Stream'],
        ['IO/Async/Timer/Countdown.pm', 'IO::Async::Timer::Countdown'],
    ) {
        my ($file, $package) = @$module;
        next if $INC{$file};
        eval "package $package; sub new { my (\$class, \%args) = \@_; bless { \%args }, \$class } 1;"
            or die $@;
        $INC{$file} = __FILE__;
    }

    unless ($INC{'JSON.pm'}) {
        eval q{
            package JSON;
            require Exporter;
            our @ISA       = qw(Exporter);
            our @EXPORT_OK = qw(encode_json);
            our @EXPORT    = qw(encode_json);
            sub encode_json { require JSON::PP; JSON::PP::encode_json($_[0]) }
            1;
        } or die $@;
        $INC{'JSON.pm'} = __FILE__;
    }

    unless ($INC{'Mediabot/External.pm'}) {
        eval q{ package Mediabot::External; 1; } or die $@;
        $INC{'Mediabot/External.pm'} = __FILE__;
    }
}

require Mediabot::Conf;
require Mediabot::Partyline;

sub write_file {
    my ($path, $text) = @_;
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $text;
    close $fh;
}

{
    package MB368::Logger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, [$level, $message];
        return 1;
    }
}

{
    package MB368::Stream;
    sub new { bless { writes => [] }, shift }
    sub write {
        my ($self, $text) = @_;
        push @{ $self->{writes} }, $text;
        return 1;
    }
}

{
    package MB368::ReloadConf;
    sub new { bless { calls => 0, fail => $_[1] }, $_[0] }
    sub reload {
        my ($self) = @_;
        $self->{calls}++;
        die "parser secret at /etc/mediabot/private.conf line 77\npassword=hunter2\n"
            if $self->{fail};
        return 1;
    }
    sub load { die "obsolete load() must never be called\n" }
}

my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/mediabot.conf";
write_file($file, "main.VALUE=old\nmain.KEEP=yes\nmain.BAD=oops\n");

my $conf = Mediabot::Conf->new(undef, $file);
my $identity = refaddr($conf);
is($conf->get('main.VALUE'), 'old', 'constructor loads the initial file through reload path');
is($conf->get('main.KEEP'), 'yes', 'initial configuration contains all parsed values');

$conf->set('main.RUNTIME_ONLY', 'discard-me');
$conf->{_get_int_diag_seen}{old_signature} = 1;
my $old_cfg_identity = refaddr($conf->{_cfg});

write_file($file, "main.VALUE=new\nmain.ADDED=present\n");
ok($conf->reload(), 'reload succeeds for a valid replacement file');
is(refaddr($conf), $identity, 'reload preserves the Mediabot::Conf object identity');
is($conf->get('main.VALUE'), 'new', 'reload publishes the new value');
is($conf->get('main.ADDED'), 'present', 'reload publishes newly added values');
ok(!defined $conf->get('main.KEEP'), 'reload removes keys absent from the replacement file');
ok(!defined $conf->get('main.RUNTIME_ONLY'), 'reload discards unsaved in-memory overrides');
isnt(refaddr($conf->{_cfg}), $old_cfg_identity, 'reload replaces the Config::Simple backing object');
is_deeply($conf->{_get_int_diag_seen}, {}, 'reload resets get_int diagnostic deduplication');

my $good_cfg_identity = refaddr($conf->{_cfg});
write_file($file, "!!PARSE-FAIL!!\n");
my $parse_ok = eval { $conf->reload(); 1 };
ok(!$parse_ok, 'invalid replacement file makes reload fail');
like($@, qr/failed to parse configuration file/, 'parse failure is explicit in the server-side exception');
is($conf->get('main.VALUE'), 'new', 'parse failure keeps the last known-good values');
is(refaddr($conf->{_cfg}), $good_cfg_identity, 'parse failure keeps the last known-good backing object');

unlink $file or die "cannot unlink $file: $!";
my $missing_ok = eval { $conf->reload(); 1 };
ok(!$missing_ok, 'missing replacement file makes reload fail');
like($@, qr/does not exist/, 'missing file failure is explicit');
is($conf->get('main.VALUE'), 'new', 'missing file keeps the last known-good values');

my $memory_only = Mediabot::Conf->new({ 'main.VALUE' => 'memory' });
my $memory_ok = eval { $memory_only->reload(); 1 };
ok(!$memory_ok, 'memory-only configuration cannot pretend to reload');
like($@, qr/no configuration file associated/, 'memory-only failure explains the missing backing file');
is($memory_only->get('main.VALUE'), 'memory', 'memory-only values remain intact after failed reload');

my $logger = MB368::Logger->new;
my $reload_conf = MB368::ReloadConf->new(0);
my $pl = bless {
    bot => { conf => $reload_conf, logger => $logger },
    users => { 10 => { level => 0, login => 'owner' } },
}, 'Mediabot::Partyline';

my $reload_stream = MB368::Stream->new;
is($pl->_cmd_reload($reload_stream, 10), 1, '.reload reports success to its caller');
is($reload_conf->{calls}, 1, '.reload calls reload() exactly once');
is_deeply($reload_stream->{writes}, ["Configuration reloaded.\r\n"], '.reload returns the historical success message');
like($logger->{entries}[0][1], qr/config reloaded by owner/, '.reload success is logged with the requesting owner');

my $reloadconf_stream = MB368::Stream->new;
is($pl->_cmd_reloadconf($reloadconf_stream, 10), 1, '.reloadconf reports success to its caller');
is($reload_conf->{calls}, 2, '.reloadconf shares the same reload() path');
is_deeply($reloadconf_stream->{writes}, ["Configuration reloaded.\r\n"], '.reloadconf uses the unified success message');

my $denied_stream = MB368::Stream->new;
$pl->{users}{11} = { level => 1, login => 'master' };
$pl->_cmd_reload($denied_stream, 11);
is($reload_conf->{calls}, 2, 'non-owner .reload does not touch the configuration');
is_deeply($denied_stream->{writes}, ["Permission denied (Owner required).\r\n"], '.reload keeps its Owner-only policy');

my $failure_logger = MB368::Logger->new;
my $failure_conf = MB368::ReloadConf->new(1);
my $failure_pl = bless {
    bot => { conf => $failure_conf, logger => $failure_logger },
    users => { 12 => { level => 0, login => 'owner' } },
}, 'Mediabot::Partyline';
my $failure_stream = MB368::Stream->new;
is($failure_pl->_cmd_reload($failure_stream, 12), 0, '.reload returns false on parser failure');
is_deeply($failure_stream->{writes}, ["Reload failed.\r\n"], '.reload keeps MB367 redaction on failure');
unlike($failure_stream->{writes}[0], qr/private|password|line 77/, '.reload leaks no parser detail to the client');
like($failure_logger->{entries}[0][1], qr/private\.conf line 77 password=hunter2/, '.reload keeps parser detail in the server log');

my $failure_reloadconf_stream = MB368::Stream->new;
is($failure_pl->_cmd_reloadconf($failure_reloadconf_stream, 12), 0, '.reloadconf returns false on parser failure');
is_deeply($failure_reloadconf_stream->{writes}, ["Configuration reload failed.\r\n"], '.reloadconf also keeps a sealed client response');

open my $cfh, '<', "$Bin/../../Mediabot/Conf.pm" or die $!;
local $/;
my $conf_src = <$cfh>;
close $cfh;
open my $pfh, '<', "$Bin/../../Mediabot/Partyline.pm" or die $!;
my $party_src = <$pfh>;
close $pfh;

like($conf_src, qr/mb368-B1/, 'MB368 marker is present in Mediabot::Conf');
like($conf_src, qr/sub reload\s*\{/, 'Mediabot::Conf exposes the real reload method');
like($party_src, qr/sub _reload_configuration_file\s*\{/, 'Partyline uses one shared checked reload path');
unlike($party_src, qr/\$bot->\{conf\}->load\s*\(/, 'Partyline no longer calls the non-existent load method');
like($party_src, qr/_cmd_reloadconf\(\$stream, \$id\)/, '.reloadconf dispatches to its testable command method');

# MB367 regression fixture must now model the actual public API.
open my $mfh, '<', "$Bin/586_mb367_partyline_command_error_redaction.t" or die $!;
my $mb367_src = <$mfh>;
close $mfh;
like($mb367_src, qr/package MB367::Conf;\s+sub reload/s, 'MB367 fixture follows the corrected reload API');
unlike($mb367_src, qr/package MB367::Conf;\s+sub load/s, 'MB367 fixture no longer blesses the obsolete API');

done_testing();
