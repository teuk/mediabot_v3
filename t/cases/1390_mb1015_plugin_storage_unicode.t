use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::PluginManager;
use Mediabot::ScriptActionRunner;
use Mediabot::Plugin::RepositoryV3;

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1015::Conf;
    sub get { $_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef }
    package MB1015::Log;
    sub log { push @{$_[0]{lines}}, [@_[1,2]]; 1 }
    package MB1015::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    sub set { $_[0]{$_[1]} = $_[2]; 1 }
    package MB1015::IRC;
    sub send_message { push @{$_[0]{sent}}, [@_[1..$#_]]; 1 }
}
my $dir = tempdir(CLEANUP => 1);
my $metrics = bless {}, 'MB1015::Metrics';
my $irc = bless {sent => []}, 'MB1015::IRC';
my $bot = {conf => bless({dir => $dir}, 'MB1015::Conf'),
    logger => bless({lines => []}, 'MB1015::Log'), metrics => $metrics, irc => $irc};
my $pm = Mediabot::PluginManager->new(bot => $bot);
my $ar = Mediabot::ScriptActionRunner->new(bot => $bot);
sub bytes_1390 {
    open my $fh, '<:raw', $_[0] or die $!;
    local $/; return <$fh>;
}
sub store_1390 {
    my ($name, $data) = @_;
    my (@warnings, @result);
    my $ok;
    {
        local $SIG{__WARN__} = sub {push @warnings, @_};
        $ok = eval {@result = $pm->_store_plugin_data($name, $data); 1};
    }
    return [@result, \@warnings, $ok ? 1 : 0];
}
my $data = {
    name => 'Été — 東京 🪄', 'clé 🧭' => '0',
    tags => ['é', '東京', '🪄', '0'],
    nested => {flag => JSON::PP::true, off => JSON::PP::false, none => undef},
    total => 7,
};
my $saved = JSON::PP->new->canonical->ascii->encode($data);
my $stored = store_1390('wide', $data);
my $back = $pm->_read_plugin_data('wide');
my $first_bytes = bytes_1390("$dir/wide.json");
is_deeply([$stored, $back, JSON::PP->new->canonical->ascii->encode($data),
           (stat("$dir/wide.json"))[2] & 0777,
           $metrics->{mediabot_plugin_storage_bytes}],
    [[1, undef, [], 1], $data, $saved, 0600, length($first_bytes)],
    'native storage preserves mixed Unicode keys/values and types without wide-print warnings');
{
    my (@actual, @expected);
    for (1..3) {
        my $read = $pm->_read_plugin_data('wide');
        push @actual, [store_1390('wide', $read), $pm->_read_plugin_data('wide'),
            bytes_1390("$dir/wide.json")];
        push @expected, [[1, undef, [], 1], $data, $first_bytes];
    }
    is_deeply(\@actual, \@expected,
        'repeated real read/write cycles keep text and physical file bytes stable');
}
{
    my $repo = Mediabot::Plugin::RepositoryV3->new(plugin => 'unicode-probe',
        reader => sub {$pm->_read_plugin_data('v3-unicode-probe')},
        writer => sub {$pm->_store_plugin_data('v3-unicode-probe', $_[1])});
    my (@warnings, @result);
    my $text = 'Bonjour — 東京 🪄';
    {
        local $SIG{__WARN__} = sub {push @warnings, @_};
        push @result, $repo->commit(expected_revision => 0, changes => {text => $text});
        push @result, $repo->snapshot;
        push @result, $repo->commit(expected_revision => 1, changes => {count => '2'});
        push @result, $repo->snapshot;
    }
    my $before = bytes_1390("$dir/v3-unicode-probe.json");
    my $conflict = $repo->commit(expected_revision => 1, changes => {text => 'stale'});
    is_deeply([\@result, \@warnings, $conflict,
               bytes_1390("$dir/v3-unicode-probe.json") eq $before ? 1 : 0],
        [[{ok => 1, revision => 1, values => {text => $text}},
          {revision => 1, values => {text => $text}},
          {ok => 1, revision => 2, values => {text => $text, count => '2'}},
          {revision => 2, values => {text => $text, count => '2'}}], [],
         {ok => 0, error => 'conflict', revision => 2}, 1],
        'API v3 repository revisions and unrelated commits preserve Unicode through the real disk boundary');
}
{
    # 11 JSON punctuation/key bytes + 2728 six-byte escapes + five ASCII bytes.
    my $exact = {blob => ('中' x 2728) . 'xxxxx'};
    my ($valid, $err) = Mediabot::ScriptActionRunner::validate_storage_object($exact);
    my $result = store_1390('limit', $exact);
    is_deeply([$valid, $err, $result, -s "$dir/limit.json", $pm->_read_plugin_data('limit')],
        [1, undef, [1, undef, [], 1], 16384, $exact],
        'exact 16 KiB serialized Unicode document is accepted and round-trips');
    my $before = bytes_1390("$dir/limit.json");
    my $count = $metrics->{mediabot_plugin_store_total};
    my $too_big = {blob => $exact->{blob} . 'x'};
    my ($action_ok, $action_error) = $ar->validate_action({type => 'store', data => $too_big}, {});
    my $denied = store_1390('limit', $too_big);
    is_deeply([$action_ok, $action_error, $denied,
               bytes_1390("$dir/limit.json") eq $before ? 1 : 0,
               $metrics->{mediabot_plugin_store_total} == $count ? 1 : 0,
               [glob("$dir/limit.json.tmp.*")]],
        [0, 'store action rejected: store data exceeds 16384 bytes',
         [0, 'store data exceeds 16384 bytes', [], 1], 1, 1, []],
        'one serialized byte over the bound is rejected by planning and writing before altering state');
}
{
    my (@actual, @expected);
    my $n = 0;
    for my $value ('ASCII', 'café', 'Ã©', 'é' x 8000) {
        my $object = {text => $value, empty => '', zero => '0', flag => JSON::PP::true};
        # This is precisely the old serializer and its raw-file representation.
        my $legacy = JSON::PP->new->canonical->encode($object);
        my $name = 'legacy' . ++$n;
        open my $fh, '>:raw', "$dir/$name.json" or die $!;
        print {$fh} $legacy or die $!;
        close $fh or die $!;
        my $read = $pm->_read_plugin_data($name);
        push @actual, [$read, store_1390($name, $read), bytes_1390("$dir/$name.json")];
        push @expected, [$object, [1, undef, [], 1], $legacy];
    }
    is_deeply(\@actual, \@expected,
        'existing ASCII/Latin-1 documents retain exact values, bytes and capacity without guessed UTF-8 decoding');
}
{
    my @warnings;
    my $plan;
    {
        local $SIG{__WARN__} = sub {push @warnings, @_};
        $plan = $ar->apply_actions({ok => 1, response => {ok => 1, actions => [
            {type => 'store', data => $data}, {type => 'reply', text => 'Saved.', target => '#test'},
        ]}}, {}, apply => 1, allow_store => 1, allow_irc => 1,
            store_sink => sub {$pm->_store_plugin_data('actions', $_[0])});
    }
    is_deeply([$plan->{applied_ok}, $plan->{apply_errors},
               [map {$_->{type}} @{$plan->{applied}}], $pm->_read_plugin_data('actions'),
               $irc->{sent}, \@warnings],
        [1, [], ['store', 'reply'], $data, [['PRIVMSG', undef, '#test', 'Saved.']], []],
        'native action planning/application persists Unicode and continues to the authorized reply');
}
{
    my $legacy = bytes_1390("$dir/legacy1.json");
    symlink("$dir/legacy1.json", "$dir/link.json") or die $!;
    my $missing = "$dir/absent";
    my $empty_bot = {conf => bless({dir => $missing}, 'MB1015::Conf'), logger => $bot->{logger}};
    my $empty_pm = Mediabot::PluginManager->new(bot => $empty_bot);
    is_deeply([$pm->_read_plugin_data('link'), $empty_pm->_read_plugin_data('none'),
               -e $missing ? 1 : 0, bytes_1390("$dir/legacy1.json")],
        [undef, undef, 0, $legacy],
        'existing symlink rejection and genuinely read-only missing-state behavior are preserved');
}
done_testing;
