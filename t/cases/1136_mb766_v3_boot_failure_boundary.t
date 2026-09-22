# MB766 — bad whole state fails closed; one missing package stays isolated.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use File::Temp qw(tempdir);
use JSON::PP ();

{
    package T1136::Conf;
    sub new { bless { dir => $_[1] }, $_[0] }
    sub get { $_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef }
}

{
    package T1136::Log;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package T1136::Bot;
    sub new {
        my ($class, $dir) = @_;
        require Mediabot::CommandRegistry;
        return bless {
            conf => T1136::Conf->new($dir), logger => T1136::Log->new,
            registry => Mediabot::CommandRegistry->new,
        }, $class;
    }
    sub command_registry { $_[0]{registry} }
    sub registry { $_[0]{registry} }
}

sub manager_1136 {
    my ($dir) = @_;
    require Mediabot::PluginManager;
    return Mediabot::PluginManager->new(
        bot => T1136::Bot->new($dir), plugin_dir => 'plugins');
}

sub write_state_1136 {
    my ($path, $document) = @_;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} JSON::PP->new->canonical->encode($document);
    close $fh or die "$path: $!";
}

return sub {
    my ($assert) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $path = "$dir/.api-v3-runtime-state.json";
    my $valid_package = {
        grants => [qw(http.fetch irc.reply storage.kv)],
        enabled => JSON::PP::false,
        policies => {},
    };

    write_state_1136($path, {
        schema => 1,
        packages => { 'short-content-v3' => $valid_package },
        surprise => 1,
    });
    my $closed = manager_1136($dir);
    my $bad = $closed->restore_v3_runtime_state;
    $assert->is($closed->count, 0,
        'unknown whole-document field loads no package');
    $assert->is(scalar @{ $bad->{errors} }, 1,
        'invalid whole document yields one bounded startup error');

    write_state_1136($path, {
        schema => 1,
        packages => {
            'missing-v3' => {
                grants => [], enabled => JSON::PP::false, policies => {},
            },
            'short-content-v3' => $valid_package,
        },
    });
    my $isolated = manager_1136($dir);
    my $report = $isolated->restore_v3_runtime_state;
    $assert->is(scalar @{ $report->{errors} }, 1,
        'missing local package is isolated as one restore error');
    $assert->is(scalar @{ $report->{loaded} }, 1,
        'remaining valid package still restores');
    $assert->ok($isolated->is_registered('short-content-v3'),
        'valid package is live after another package fails');
    $assert->ok(!$isolated->is_registered('missing-v3'),
        'missing package remains absent');

    my $blocked_root = tempdir(CLEANUP => 1);
    my $blocked_path = "$blocked_root/not-a-directory";
    open my $blocked, '>:raw', $blocked_path or die "$blocked_path: $!";
    print {$blocked} "blocked\n";
    close $blocked;
    my $rollback = manager_1136($blocked_path);
    my $loaded = eval {
        $rollback->load_package_v3_persistent('short-content-v3', grants => [
            qw(http.fetch irc.reply storage.kv)
        ]);
        1;
    };
    $assert->ok(!$loaded,
        'persistent load reports an unwritable state boundary');
    $assert->like($@ // '', qr/state was not persisted/,
        'persistent load failure is explicit');
    $assert->is($rollback->count, 0,
        'failed persistent load rolls the in-memory package back');
    $assert->ok(!$rollback->{bot}{registry}->has_command('short', 'public'),
        'failed persistent load restores the command registry');
};
