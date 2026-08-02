# t/cases/775_mb591_plugin_v2_precommit_hardening.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP ();

{
    package Mediabot::Helpers;
    our @NOTICES;
    sub botNotice {
        my (undef, $nick, $text) = @_;
        push @NOTICES, "$nick: $text";
        return 1;
    }
    sub get_user_from_message { return undef }
}

{
    package Log775;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, $_[2]; return 1 }
}
{
    package Reg775;
    our @ISA;
    sub fail_once {
        my ($self, $name) = @_;
        $self->{fail_once} = $name;
    }
    sub register_command {
        my ($self, %args) = @_;
        if (defined $self->{fail_once}
            && $self->{fail_once} eq ($args{name} // '')) {
            delete $self->{fail_once};
            die "simulated registry mount failure\n";
        }
        return $self->SUPER::register_command(%args);
    }
}
{
    package AR775;
    sub new { bless { plan => { applied_ok => 1, apply_errors => [] } }, shift }
    sub apply_actions { return $_[0]{plan} }
}
{
    package Bot775;
    sub new {
        my ($class, %args) = @_;
        bless {
            registry => $args{registry},
            runner   => $args{runner},
            ar       => $args{ar},
            logger   => Log775->new,
        }, $class;
    }
    sub registry { $_[0]{registry} }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0]{ar} }
    sub events { undef }
}
{
    package Ctx775;
    sub new { bless { @_ > 1 ? @_[1..$#_] : () }, shift }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} || [] }
    sub message { $_[0]{message} }
}
{
    package T775::NoObject;
    sub manifest {
        return {
            api => 2, name => 'noobject', version => '1.0',
            commands => { noobj775 => { help => 'No object.', level => 0 } },
        };
    }
    sub register { return undef }
    sub command_noobj775 { return 'bad' }
    $INC{'T775/NoObject.pm'} = __FILE__;
}
{
    package T775::NoRegistry;
    sub manifest {
        return {
            api => 2, name => 'noregistry', version => '1.0',
            commands => { noreg775 => { help => 'No registry.', level => 0 } },
        };
    }
    sub register { bless {}, shift }
    sub command_noreg775 { return 'bad' }
    $INC{'T775/NoRegistry.pm'} = __FILE__;
}

sub _write_775 {
    my ($root, $rel, $content) = @_;
    my $path = "$root/$rel";
    (my $parent = $path) =~ s{/[^/]+\z}{};
    make_path($parent);
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

return sub {
    my ($assert) = @_;

    require Mediabot::CommandRegistry;
    @Reg775::ISA = ('Mediabot::CommandRegistry');
    require Mediabot::ScriptRunner;
    require Mediabot::PluginManager;

    my $dir = tempdir(CLEANUP => 1);
    my $reg = Reg775->new;
    my $ar = AR775->new;
    my $bot = Bot775->new(registry => $reg, ar => $ar);
    my $runner = Mediabot::ScriptRunner->new(bot => $bot, script_dir => $dir);
    $bot->{runner} = $runner;

    # Module commands require both a registry and a real registered object.
    my $pm = Mediabot::PluginManager->new(bot => $bot);
    my $ok = eval { $pm->load_perl_module('T775::NoObject'); 1 };
    $assert->ok(!$ok, 'mb591-775: command plugin without object rejected');
    $assert->like($@ // '', qr/commands require a registered object/,
        'mb591-775: object refusal is explicit');
    $assert->ok(!$pm->is_registered('noobject'),
        'mb591-775: object refusal leaves no half-registered plugin');

    my $bot_no_reg = Bot775->new(registry => undef, runner => $runner, ar => $ar);
    my $pm_no_reg = Mediabot::PluginManager->new(bot => $bot_no_reg);
    $ok = eval { $pm_no_reg->load_perl_module('T775::NoRegistry'); 1 };
    $assert->ok(!$ok, 'mb591-775: command plugin without registry rejected');
    $assert->like($@ // '', qr/command registry unavailable/,
        'mb591-775: registry refusal is explicit');
    $assert->ok(!$pm_no_reg->is_registered('noregistry'),
        'mb591-775: registry refusal leaves no half-registered plugin');

    # Missing scripts are rejected at load time, not deferred to first dispatch.
    _write_775($dir, 'missing.py.manifest.json', JSON::PP::encode_json({
        api => 2, name => 'missing', version => '1.0',
        commands => { missing775 => { help => 'Missing.', level => 0 } },
    }));
    $ok = eval { $pm->load_script_v2('missing.py'); 1 };
    $assert->ok(!$ok, 'mb591-775: missing script rejected at load');
    $assert->like($@ // '', qr/script file not found or not regular/,
        'mb591-775: missing script diagnostic is explicit');

    # Sidecar symlink escape is checked independently from the script path.
    _write_775($dir, 'escape.py', "print('x')\n");
    my $outside = tempdir(CLEANUP => 1);
    my $outside_manifest = _write_775($outside, 'outside.json',
        JSON::PP::encode_json({
            api => 2, name => 'escape', version => '1.0',
            commands => { escape775 => { help => 'Escape.', level => 0 } },
        }));
    my $link = "$dir/escape.py.manifest.json";
    my $symlink_ok = symlink($outside_manifest, $link);
    if ($symlink_ok) {
        $ok = eval { $pm->load_script_v2('escape.py'); 1 };
        $assert->ok(!$ok, 'mb591-775: sidecar symlink escape rejected');
        $assert->like($@ // '', qr/invalid sidecar path/,
            'mb591-775: sidecar containment diagnostic is explicit');
    }
    else {
        $assert->ok(1, 'mb591-775: symlink unavailable on this platform');
        $assert->ok(1, 'mb591-775: sidecar containment diagnostic skipped');
    }

    # Replace is transactional and preserves disabled state.
    _write_775($dir, 'greet.py', "print('hi')\n");
    my $manifest = {
        api => 2, name => 'greet', version => '1.0',
        commands => { greet775 => { help => 'Greet.', level => 0 } },
    };
    _write_775($dir, 'greet.py.manifest.json', JSON::PP::encode_json($manifest));
    my $entry = $pm->load_script_v2('greet.py');
    $pm->disable('greet');
    $assert->is($pm->is_enabled('greet'), 0,
        'mb591-775: fixture plugin disabled before reload');

    _write_775($dir, 'greet.py.manifest.json',
        JSON::PP::encode_json({ %$manifest, version => '2.0' }));
    $reg->fail_once('greet775');
    $ok = eval { $pm->load_script_v2('greet.py', replace => 1); 1 };
    $assert->ok(!$ok, 'mb591-775: simulated replacement mount failure reported');
    $assert->is($pm->plugin('greet')->{version}, '1.0',
        'mb591-775: previous entry restored after mount failure');
    $assert->is($reg->has_command('greet775', 'public'), 1,
        'mb591-775: previous command restored after mount failure');
    $assert->is($pm->is_enabled('greet'), 0,
        'mb591-775: previous disabled state survives rollback');

    my $new_entry = $pm->load_script_v2('greet.py', replace => 1);
    $assert->is($new_entry->{version}, '2.0',
        'mb591-775: later valid replacement succeeds');
    $assert->is($pm->is_enabled('greet'), 0,
        'mb591-775: successful reload preserves disabled state');

    # An apply plan with action errors is not reported as command success.
    _write_775($dir, 'action.py', "print('action')\n");
    _write_775($dir, 'action.py.manifest.json', JSON::PP::encode_json({
        api => 2, name => 'action', version => '1.0',
        commands => { action775 => { help => 'Action.', level => 0 } },
    }));
    my $action_entry = $pm->load_script_v2('action.py');

    no warnings 'redefine';
    local *Mediabot::ScriptRunner::run_script = sub {
        return { ok => 1, actions => [ { type => 'topic', text => 'x' } ] };
    };
    $ar->{plan} = {
        applied_ok => 0,
        apply_errors => [ { error => 'topic actions require allow_topic' } ],
    };
    @Mediabot::Helpers::NOTICES = ();
    my $handler = $reg->handler_for('action775', 'public');
    my $result = $handler->(Ctx775->new(
        nick => 'Teuk', channel => '#i/o', args => [], message => {},
    ));
    $assert->ok(!defined $result,
        'mb591-775: action-plan failure is not returned as success');
    $assert->like($Mediabot::Helpers::NOTICES[0] // '',
        qr/Teuk: Command 'action775' completed with action errors\./,
        'mb591-775: action-plan failure is notified');

    # Legacy/custom action runners may return a scalar instead of a plan.
    # The plugin wrapper must fail cleanly rather than dereference it.
    $ar->{plan} = 1;
    @Mediabot::Helpers::NOTICES = ();
    my $scalar_ok = eval {
        $result = $handler->(Ctx775->new(
            nick => 'Teuk', channel => '#i/o', args => [], message => {},
        ));
        1;
    };
    $assert->ok($scalar_ok,
        'mb591-B3-775: scalar action result does not crash dispatch');
    $assert->ok(!defined $result,
        'mb591-B3-775: scalar action result is not reported as success');
    $assert->like($Mediabot::Helpers::NOTICES[0] // '',
        qr/Teuk: Command 'action775' completed with action errors\./,
        'mb591-B3-775: scalar action result is notified');

    # Diagnostics are allowed to be strings or hashes. Nested values receive
    # the generic fallback and must never crash the error path.
    $ar->{plan} = {
        applied_ok => 0,
        apply_errors => [
            'plain apply failure',
            { error => 'hash apply failure' },
            [],
        ],
    };
    @Mediabot::Helpers::NOTICES = ();
    my $mixed_ok = eval {
        $result = $handler->(Ctx775->new(
            nick => 'Teuk', channel => '#i/o', args => [], message => {},
        ));
        1;
    };
    $assert->ok($mixed_ok,
        'mb591-B3-775: mixed apply_errors do not crash dispatch');
    $assert->ok(!defined $result,
        'mb591-B3-775: mixed apply_errors remain a command failure');
    $assert->like($Mediabot::Helpers::NOTICES[0] // '',
        qr/Teuk: Command 'action775' completed with action errors\./,
        'mb591-B3-775: mixed apply_errors are notified');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/PluginManager.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($src, qr/while \(length\(\$json\) <= \$MAX_SIDECAR_BYTES\)/,
        'mb591-775: sidecar reader is bounded before JSON decode');
    $assert->unlike($src, qr/my \$json = do \{ local \$\/; <\$fh> \}/,
        'mb591-775: unbounded sidecar slurp removed');

    my $party = do {
        open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($party,
        qr/\.plugins \[loaded\|config\|info\|load\|loadscript\|unload\|reload\|enable\|disable\|cleardata\]/,
        'mb591-775: partyline help includes loadscript');
};
