# t/cases/785_mb602_plugin_storage_boundary_hardening.t
# =============================================================================
# mb602 — pre-commit boundary hardening for mb598..mb601.
#   [1] Storage JSON booleans are valid and one shared validator protects
#       planning, writes and reads.
#   [2] Storage names cannot traverse paths; reads and .plugins info never
#       create DATA_DIR; symlinks and malformed local data are ignored.
#   [3] .plugins info is one-line bounded and redacts likely credentials.
#   [4] Nested runner diagnostics survive; action-apply failures increment
#       plugin failure metrics for commands and events.
#   [5] greeter.tcl treats operator % text literally rather than as a Tcl
#       format program.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);

{
    package Conf785;
    sub new { bless { kv => $_[1] || {} }, $_[0] }
    sub get { $_[0]{kv}{ $_[1] } }
}
{
    package Log785;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}
{
    package Metrics785;
    sub new { bless { values => {} }, shift }
    sub _key {
        my ($name, $labels) = @_;
        return join "\x1e", $name,
            map { $_ . '=' . ($labels->{$_} // '') } sort keys %{ $labels || {} };
    }
    sub inc {
        my ($self, $name, $labels) = @_;
        $self->{values}{ _key($name, $labels) }++;
        return 1;
    }
    sub get {
        my ($self, $name, $labels) = @_;
        return $self->{values}{ _key($name, $labels) } // 0;
    }
}
{
    package Bot785;
    sub new {
        my ($class, $data_dir) = @_;
        return bless {
            conf    => Conf785->new({ 'plugins.DATA_DIR' => $data_dir }),
            logger  => Log785->new,
            metrics => Metrics785->new,
        }, $class;
    }
    sub plugin_manager { $_[0]{pm} }
    sub plugin_autoload_enabled { 0 }
    sub script_runner { $_[0]{runner} }
    sub script_action_runner { $_[0]{action_runner} }
}
{
    package Stream785;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
}
{
    package Ctx785;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} || [] }
    sub message { $_[0]{message} || {} }
}
{
    package Runner785;
    sub new { bless { result => $_[1] }, $_[0] }
    sub run_script { $_[0]{result} }
}
{
    package ActionRunner785;
    sub new { bless { plan => $_[1] }, $_[0] }
    sub apply_actions { $_[0]{plan} }
}

return sub {
    my ($assert) = @_;

    require Mediabot::PluginManager;
    require Mediabot::ScriptActionRunner;
    require Mediabot::Helpers;

    no warnings 'redefine';
    local *Mediabot::Helpers::botNotice = sub { 1 };

    my $root = tempdir(CLEANUP => 1);
    my $data_dir = "$root/plugin-data";
    my $bot = Bot785->new($data_dir);
    my $pm = Mediabot::PluginManager->new(bot => $bot);
    $bot->{pm} = $pm;
    my $ar = Mediabot::ScriptActionRunner->new(bot => $bot);

    # [1] JSON booleans and the shared storage validator.
    my ($ok, $err) = Mediabot::ScriptActionRunner::validate_storage_object({
        enabled => JSON::PP::true,
        nested  => { disabled => JSON::PP::false },
    });
    $assert->ok($ok, 'mb602-785: shared validator accepts JSON booleans');

    ($ok, $err) = $ar->validate_action({
        type => 'store', data => { enabled => JSON::PP::true },
    }, {});
    $assert->ok($ok, 'mb602-785: store action accepts a JSON boolean');

    # Read-only paths must not create DATA_DIR.
    my ($info, $info_err) = $pm->plugin_data_info('safe');
    $assert->ok(!defined($info) && !defined($info_err),
        'mb602-785: missing storage has no info and no error');
    $assert->ok(!-e $data_dir,
        'mb602-785: plugin_data_info does not create DATA_DIR');

    # [2] Slug validation closes cleardata/path traversal.
    my $sentinel = "$root/escape.json";
    open my $sentinel_fh, '>:raw', $sentinel or die $!;
    print {$sentinel_fh} '{"keep":true}';
    close $sentinel_fh;

    my ($bad_path, $bad_path_err) = $pm->_plugin_data_path('../escape');
    $assert->ok(!defined($bad_path) && ($bad_path_err // '') =~ /invalid plugin storage name/,
        'mb602-785: traversal is rejected at path resolution');

    my ($clear_ok, $removed, $clear_err) = $pm->clear_plugin_data('../escape');
    $assert->ok(!$clear_ok && !$removed && ($clear_err // '') =~ /invalid plugin storage name/,
        'mb602-785: cleardata rejects traversal');
    $assert->ok(-f $sentinel,
        'mb602-785: traversal rejection leaves the outside sentinel untouched');

    ($ok, $err) = $pm->_store_plugin_data('safe', {
        a => { b => { c => { d => 1 } } },
    });
    $assert->ok(!$ok && ($err // '') =~ /deeper than 3/,
        'mb602-785: write boundary repeats the depth limit');

    ($ok, $err) = $pm->_store_plugin_data('safe', {
        ('K' x 65) => 1,
    });
    $assert->ok(!$ok && ($err // '') =~ /longer than 64/,
        'mb602-785: write boundary repeats the key-length limit');

    ($ok, $err) = $pm->_store_plugin_data('safe', {
        enabled => JSON::PP::true,
        disabled => JSON::PP::false,
    });
    $assert->ok($ok, 'mb602-785: valid boolean storage writes successfully');
    $assert->ok(-f "$data_dir/safe.json",
        'mb602-785: a store action creates the bot-owned file');

    my $back = $pm->_read_plugin_data('safe');
    $assert->ok(ref($back) eq 'HASH',
        'mb602-785: valid storage reads back as an object');
    $assert->ok(JSON::PP::is_bool($back->{enabled}) && $back->{enabled},
        'mb602-785: true survives the disk roundtrip');
    $assert->ok(JSON::PP::is_bool($back->{disabled}) && !$back->{disabled},
        'mb602-785: false survives the disk roundtrip');

    ($info, $info_err) = $pm->plugin_data_info('safe');
    $assert->ok(ref($info) eq 'HASH' && !defined($info_err),
        'mb602-785: plugin_data_info returns structured metadata');
    $assert->ok(($info->{size} // 0) > 0,
        'mb602-785: storage metadata reports a real byte size');
    $assert->like($info->{path} // '', qr/\Q$data_dir\E\/safe\.json\z/,
        'mb602-785: storage metadata reports the validated path');

    open my $deep_fh, '>:raw', "$data_dir/deep.json" or die $!;
    print {$deep_fh} JSON::PP->new->canonical->encode({
        a => { b => { c => { d => 1 } } },
    });
    close $deep_fh;
    $assert->ok(!defined $pm->_read_plugin_data('deep'),
        'mb602-785: manually written over-deep storage is ignored');
    $assert->ok((grep { ($_->[1] // '') =~ /invalid storage file for 'deep'.*deeper than 3/ }
        @{ $bot->{logger}{lines} }),
        'mb602-785: invalid local storage is diagnosed without dispatch failure');

    my $link_path = "$data_dir/link.json";
    my $linked = symlink($sentinel, $link_path);
    $assert->ok($linked && -l $link_path,
        'mb602-785: symlink fixture created');
    $assert->ok(!defined $pm->_read_plugin_data('link'),
        'mb602-785: symlink storage is never followed');

    ($clear_ok, $removed, $clear_err) = $pm->clear_plugin_data('safe');
    $assert->ok($clear_ok && $removed && !defined($clear_err),
        'mb602-785: a validated plugin storage file can be cleared');
    $assert->ok(!-e "$data_dir/safe.json",
        'mb602-785: clear removes only the validated file');
    ($clear_ok, $removed, $clear_err) = $pm->clear_plugin_data('safe');
    $assert->ok($clear_ok && !$removed && !defined($clear_err),
        'mb602-785: clearing missing data is idempotent');

    # [3] .plugins info: read-only rendering, secret redaction, no injection.
    my $info_data_dir = "$root/info-data";
    my $info_bot = Bot785->new($info_data_dir);
    my $info_pm = Mediabot::PluginManager->new(bot => $info_bot);
    $info_bot->{pm} = $info_pm;
    $info_pm->register_plugin(
        name => 'view', version => '1.0',
        description => "Line one\r\nFORGED DESCRIPTION",
        metadata => { api => 2, kind => 'script', script_path => 'view.py' },
        manifest => {
            api => 2, name => 'view', version => '1.0',
            commands => {
                look785 => { level => 0, help => "Safe help\nFORGED HELP" },
            },
            events => [],
        },
        plugin_config => {
            API_KEY  => 'super-secret-value',
            AUTHOR   => 'Teuk',
            GREETING => "Hello\r\nFORGED CONFIG",
        },
    );

    require Mediabot::Partyline;
    my $partyline = bless {
        bot => $info_bot,
        users => { 7 => { level => 1 } },
        streams => {},
    }, 'Mediabot::Partyline';
    my $stream = Stream785->new;
    $partyline->_cmd_plugins($stream, 7, 'info view');
    my $out = $stream->{out};

    $assert->like($out, qr/Plugin 'view' \[enabled\] kind=script api=2 version=1\.0/,
        'mb602-785: info still renders the plugin identity');
    $assert->like($out, qr/config: API_KEY=\[redacted\]/,
        'mb602-785: likely credential config is redacted');
    $assert->unlike($out, qr/super-secret-value/,
        'mb602-785: the real credential never reaches partyline output');
    $assert->like($out, qr/config: AUTHOR=Teuk/,
        'mb602-785: ordinary non-secret config remains visible');
    $assert->like($out, qr/config: GREETING=Hello FORGED CONFIG/,
        'mb602-785: config control characters collapse to one line');
    $assert->like($out, qr/description: Line one FORGED DESCRIPTION/,
        'mb602-785: description control characters collapse to one line');
    $assert->like($out, qr/Safe help FORGED HELP/,
        'mb602-785: command help control characters collapse to one line');
    $assert->unlike($out, qr/\r\n(?:FORGED DESCRIPTION|FORGED CONFIG|FORGED HELP)/,
        'mb602-785: manifest/config text cannot inject partyline lines');
    $assert->ok(!-e $info_data_dir,
        'mb602-785: .plugins info remains filesystem read-only');

    # [4] Diagnostics and end-to-end failure metrics.
    my $nested = Mediabot::PluginManager::_script_result_error({
        ok => 0,
        response => { errors => [ 'nested failure one', 'nested failure two' ] },
    }, '');
    $assert->is($nested, 'nested failure one; nested failure two',
        'mb602-785: nested ScriptRunner diagnostics are preserved');
    $assert->is(Mediabot::PluginManager::_script_result_error(
        { ok => 0, timeout => 1 }, ''), 'script timed out',
        'mb602-785: timeout keeps an explicit diagnostic');

    my $metric_bot = Bot785->new("$root/metric-data");
    $metric_bot->{runner} = Runner785->new({
        ok => 1, response => { ok => 1, actions => [] },
    });
    $metric_bot->{action_runner} = ActionRunner785->new({
        applied_ok => 0,
        apply_errors => [ { error => 'apply denied' } ],
    });
    my $metric_pm = Mediabot::PluginManager->new(bot => $metric_bot);
    my $entry = {
        metadata => { kind => 'script', script_path => 'probe.py' },
        plugin_config => undef,
    };
    my $ctx = Ctx785->new(nick => 'Teuk', channel => '#i/o', args => [], message => {});

    $metric_pm->_dispatch_script_command('metric', $entry, 'probe785', $ctx);
    $assert->is($metric_bot->{metrics}->get(
        'mediabot_plugin_script_failure_total',
        { plugin => 'metric', kind => 'command' }), 1,
        'mb602-785: command action-apply failure increments failure metric');
    $assert->ok((grep { ($_->[1] // '') =~ /command 'probe785' action apply failed: apply denied/ }
        @{ $metric_bot->{logger}{lines} }),
        'mb602-785: command action-apply detail reaches the log');

    $metric_pm->_dispatch_script_event('metric', $entry,
        'channel_join_observed', { channel => '#i/o', nick => 'Teuk' });
    $assert->is($metric_bot->{metrics}->get(
        'mediabot_plugin_script_failure_total',
        { plugin => 'metric', kind => 'event' }), 1,
        'mb602-785: event action-apply failure increments failure metric');
    $assert->ok((grep { ($_->[1] // '') =~ /event 'channel_join_observed' action apply failed: apply denied/ }
        @{ $metric_bot->{logger}{lines} }),
        'mb602-785: event action-apply detail reaches the log');

    # [5] The configured greeter treats percent signs as literal text.
    my ($in, $out_fh, $err_fh);
    $err_fh = gensym;
    my $greeter = "$Bin/../../plugins/scripts/examples-v2/greeter.tcl";
    my $pid = open3($in, $out_fh, $err_fh, 'tclsh', $greeter);
    print {$in} JSON::PP::encode_json({
        event => 'channel_join_observed',
        data => {
            nick => 'SlaY', is_self => 0,
            config => { GREETING => '100% welcome, %s' },
        },
    });
    close $in;
    local $/;
    my $greeter_out = <$out_fh> // '';
    my $greeter_err = <$err_fh> // '';
    waitpid($pid, 0);
    my $exit = $? >> 8;

    $assert->is($exit, 0,
        'mb602-785: greeter does not crash on a literal percent sign');
    my $decoded = eval { JSON::PP::decode_json($greeter_out) };
    $assert->ok(ref($decoded) eq 'HASH' && $decoded->{ok},
        'mb602-785: percent-safe greeter still returns valid protocol JSON');
    my ($reply) = grep { ref($_) eq 'HASH' && ($_->{type} // '') eq 'reply' }
        @{ ref($decoded) eq 'HASH' && ref($decoded->{actions}) eq 'ARRAY'
            ? $decoded->{actions} : [] };
    $assert->is($reply->{text} // '', '100% welcome, SlaY',
        'mb602-785: %s is replaced literally and other percent text survives');

    my $cookbook = do {
        open my $fh, '<:encoding(UTF-8)', 'plugins/scripts/COOKBOOK.md' or die $!;
        local $/;
        <$fh>;
    };
    $assert->like($cookbook,
        qr/JSON booleans are valid storage\s+leaves.*sensitive config keys are redacted/s,
        'mb602-785: cookbook documents the hardened storage/info boundary');
};
