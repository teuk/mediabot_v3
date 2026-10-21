use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Scalar::Util qw(refaddr);
use IPC::Open3;
use Symbol qw(gensym);
use Mediabot::IRC::Output qw(privmsg action notice);
use Mediabot::CommandAsync ();
use MB881OutputFixture;

for my $module (qw(Output Sender DeferredOutput)) {
    my $err = gensym;
    my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we',
        "require Mediabot::IRC::$module;" . q{
        die 'runtime dependency' if $INC{'Mediabot/Helpers.pm'} || $INC{'Mediabot/External/Claude.pm'};
        print 'loaded';});
    my $stdout = do {local $/; <$out>} // '';
    my $stderr = do {local $/; <$err>} // '';
    waitpid($pid, 0);
    is($?, 0, "$module loads without circular runtime imports");
    is($stdout, 'loaded', "$module does not eagerly load Helpers or Claude");
    is($stderr, '', "$module loads without redefinition diagnostics");
}

MB881OutputFixture::with_policy(sub {
    for my $row ([\&privmsg, 'privmsg'], [\&action, 'action'], [\&notice, 'notice']) {
        my ($send, $kind) = @$row;
        for my $target ('#test', '&local', '!safe', '+modeless', 'Nick') {
            my $bot = MB881OutputFixture::new_bot();
            $send->($bot, $target, '0');
            is(scalar @{$bot->{irc}{wire}}, 1, "$kind retains zero text and every historical target type");
            is($bot->{irc}{wire}[0]{target}, $target, "$kind preserves the target");
            is($bot->{irc}{wire}[0]{text}, $kind eq 'action' ? "\1ACTION 0\1" : '0', "$kind preserves its wire envelope");
        }
        for my $text ('é🙂' x 100, encode('UTF-8', 'é🙂' x 100)) {
            my $bot = MB881OutputFixture::new_bot();
            $send->($bot, 'Nick', $text);
            my @wire = @{$bot->{irc}{wire}};
            cmp_ok(scalar @wire, '>', 1, "$kind still splits long output");
            ok(!grep({length($_->{text}) > 400 || utf8::is_utf8($_->{text})} @wire), "$kind sends bounded encoded buffers");
            my $joined = join('', map {my $p = $_->{text}; $p =~ s/\A\x01ACTION |\x01\z//g if $kind eq 'action'; $p} @wire);
            is($joined, utf8::is_utf8($text) ? encode('UTF-8', $text) : $text, "$kind preserves complete UTF-8 content");
            my $expected = $kind eq 'privmsg' ? 'mediabot_privmsg_out_total' : $kind eq 'notice' ? 'mediabot_notice_out_total' : undef;
            is($expected ? $bot->{metrics}{counts}{$expected} : scalar keys %{$bot->{metrics}{counts}},
                $expected ? scalar @wire : 0, "$kind preserves its own metric convention");
        }
        my $bot = MB881OutputFixture::new_bot();
        $send->($bot, 'NickServ', 'identify account fixture-secret');
        like($bot->{irc}{wire}[0]{text}, qr/fixture-secret/, "$kind retains the actual service payload");
        unlike(join('\n', map {$_->[1]} @{$bot->{logger}{rows}}), qr/fixture-secret/, "$kind masks credentials at every log level");
        is(scalar @{$bot->{events}}, 0, "$kind private output does not create channel history");
        $bot = MB881OutputFixture::new_bot();
        $send->($bot, '#test', "one\r\ntwo\0tail");
        unlike(join('', map {$_->{text}} @{$bot->{irc}{wire}}), qr/[\r\n\0]/, "$kind keeps single-line wire sanitation");
        unlike(join('', map {$_->[1]} @{$bot->{logger}{rows}}), qr/[\r\n\0]/,
            "$kind sanitizes every log before emitting diagnostics");
        unlike(join('', map {join('', map {defined($_) && !ref($_) ? $_ : ''} @$_)} @{$bot->{events}}), qr/[\r\n\0]/,
            "$kind sanitizes history and console event text before recording it");
        $bot = MB881OutputFixture::new_bot();
        $send->($bot, undef, 'text'); $send->($bot, '#test', undef); $send->($bot, '#test', '');
        is(scalar @{$bot->{irc}{wire}}, 0, "$kind retains missing-target and empty-text guards");
    }

    for my $send (\&privmsg, \&action) {
        my $bot = MB881OutputFixture::new_bot();
        $bot->{policy}{NoColors} = 1;
        $send->($bot, '#test', "\x0304red\x0f \x02bold\x02");
        unlike($bot->{irc}{wire}[0]{text}, qr/[\x02\x03\x0f]/, 'NoColors still applies to public messages and actions');
        $bot = MB881OutputFixture::new_bot(); $bot->{dbh}{words} = ['BLOCKED'];
        $send->($bot, '#test', 'a blocked word');
        is(scalar @{$bot->{irc}{wire}}, 0, 'fresh badword rules still reject output');
        ok(!grep({$_->[0] eq 'history'} @{$bot->{events}}), 'badword rejection cannot enter history');
        ok(!grep({$_->[1] =~ /\[LIVE\]/} @{$bot->{logger}{rows}}), 'badword rejection cannot claim LIVE output');
        ok(grep({$_->[0] eq 'console'} @{$bot->{events}}), 'badword rejection keeps its explicit diagnostic');
        is($bot->{dbh}{finishes}, 1, 'successful fresh badword query is finished');
        is_deeply($bot->{dbh}{queries}[0]{bind}, ['#test'], 'badword query keeps its bound target');
        $bot = MB881OutputFixture::new_bot();
        $send->($bot, '#test', 'first'); $send->($bot, '#test', 'second');
        is(scalar @{$bot->{dbh}{queries}}, 1, 'badword cache is still reused');
        for my $failure (qw(prepare execute)) {
            $bot = MB881OutputFixture::new_bot(); $bot->{dbh}{failure} = $failure;
            $send->($bot, '#test', 'legacy fallback');
            is(scalar @{$bot->{irc}{wire}}, 1, 'DB failure retains the existing diagnostic-and-send behavior');
            is($bot->{metrics}{counts}{mediabot_db_query_errors_total}, 1, 'DB failure retains its error metric');
            is($bot->{dbh}{finishes}, $failure eq 'execute' ? 1 : 0, 'DB failure retains statement cleanup');
        }
    }
    my $bot = MB881OutputFixture::new_bot(); $bot->{policy}{NoColors} = 1;
    notice($bot, '#test', "\x0304red\x0f");
    is($bot->{irc}{wire}[0]{text}, "\x0304red\x0f", 'NOTICE retains its distinct historical color behavior');
    $bot = MB881OutputFixture::new_bot(); $bot->{policy}{AntiFlood} = 1; $bot->{blocked} = 1;
    is(privmsg($bot, '#test', 'ephemeral', {no_defer => 1}), 0, 'no_defer keeps explicit rejection while flooded');
    ok(!exists $bot->{_flood_outq}, 'no_defer cannot create queued work');
    is(privmsg($bot, '#test', 'durable'), 1, 'ordinary flood deferral retains its acceptance result');
    is_deeply($bot->{_flood_outq}{'#test'}{items}, [['privmsg', 'durable']], 'ordinary output reaches the same deferred state');
});

my @leaked;
{
    no warnings 'redefine';
    local *Mediabot::Helpers::botPrivmsg = sub {push @leaked, [@_]; 1};
    local *Mediabot::Helpers::botAction = sub {push @leaked, [@_]; 1};
    local *Mediabot::Helpers::botNotice = sub {push @leaked, [@_]; 1};
    my $options = {no_defer => 1};
    is(privmsg({}, '#test', 'options', $options), 1, 'public API resolves the legacy facade at call time');
    is(refaddr($leaked[-1][3]), refaddr($options), 'public API forwards the original option object');
    @leaked = ();
    my ($intents, $truncated, $ok, $error) = Mediabot::CommandAsync::_collect_intents_run(sub {
        privmsg({}, '#test', 'imported'); action({}, '#test', 'imported action'); notice({}, 'nick', 'imported notice');
        Mediabot::IRC::Output::privmsg({}, '#test', 'qualified');
        Mediabot::IRC::Output::action({}, '#test', 'qualified action');
        Mediabot::IRC::Output::notice({}, 'nick', 'qualified notice');
        1;
    });
    ok($ok && !defined($error), 'actual worker collector accepts imported and qualified API calls');
    is_deeply([map {$_->[0]} @$intents], [qw(privmsg action notice privmsg action notice)], 'worker collector preserves kinds and order');
    is(scalar @leaked, 0, 'public API cannot bypass worker output capture');
}
done_testing;
