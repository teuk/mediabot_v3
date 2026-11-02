use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Scalar::Util qw(refaddr);
use IPC::Open3;
use Symbol qw(gensym);
use DBI;
use Mediabot::IRC::Output qw(privmsg action notice);
use Mediabot::CommandAsync ();
use MB881OutputFixture;
my @warnings_1073;
local $SIG{__WARN__}=sub {push @warnings_1073,@_};

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
        is_deeply([scalar @{$bot->{irc}{wire}},
            scalar(grep {$_->[0] eq 'history'} @{$bot->{events}}),
            scalar(grep {$_->[1] =~ /\[LIVE\]/} @{$bot->{logger}{rows}}),
            scalar(grep {$_->[0] eq 'console'} @{$bot->{events}}),
            $bot->{dbh}{finishes},$bot->{dbh}{queries}[0]{bind}],
            [0,0,0,1,1,['#test']],
            'fresh badword rejection keeps its diagnostic and bound-query cleanup without wire/history/LIVE');
        $bot = MB881OutputFixture::new_bot();
        $send->($bot, '#test', 'first'); $send->($bot, '#test', 'second');
        is(scalar @{$bot->{dbh}{queries}}, 1, 'badword cache is still reused');
        for my $failure (qw(prepare execute)) {
            $bot = MB881OutputFixture::new_bot(); $bot->{dbh}{failure} = $failure;
            $send->($bot, '#test', 'legacy fallback');
            is_deeply([scalar @{$bot->{irc}{wire}},
                $bot->{metrics}{counts}{mediabot_db_query_errors_total},$bot->{dbh}{finishes},
                exists($bot->{_badword_cache}{'#test'})?1:0],
                [1,1,$failure eq 'execute'?1:0,0],
                'initial DB failure retains diagnostic-and-send behavior and cleanup without caching a failed read');
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
# Fault injection delegates SQL, rows and DBI error/exception behavior to SQLite.
# finish deliberately clears err, so the reader must decide before cleanup.
{
    package MB1073::DBI;our @ISA=('DBI');
    package MB1073::DBI::db;our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@args)=@_;
        my $read=$sql=~/SELECT\s+badword\s+FROM\s+CHANNEL\b/i;
        $db->{private_reads}++ if $read;
        return $db->set_err(1901,'private badword prepare detail')
            if $read && ($db->{private_fault}//'') eq 'prepare';
        my $sth=$db->SUPER::prepare($sql,@args);
        $sth->{private_read}=$read?1:0 if $sth;
        return $sth;
    }
    package MB1073::DBI::st;our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        $sth->{private_rows}=0;
        if ($sth->{private_read}) {
            $sth->{Database}{private_bind}=\@bind;
            return $sth->set_err(1902,'private badword execute detail')
                if ($sth->{Database}{private_fault}//'') eq 'execute';
        }
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth,@args)=@_;
        my $fault=$sth->{Database}{private_fault}//'';
        return $sth->set_err(1903,'private badword fetch detail')
            if $sth->{private_read} && ($fault eq 'fetch_first'
                || ($fault eq 'fetch_after_one' && $sth->{private_rows}));
        my $row=$sth->SUPER::fetchrow_hashref(@args);
        $sth->{private_rows}++ if $row;
        return $row;
    }
    sub finish {
        my ($sth)=@_;
        if ($sth->{private_read}) {
            $sth->{Database}{private_finishes}++;
            $sth->set_err(undef,undef);
        }
        return $sth->SUPER::finish;
    }
}
$INC{'MB1073/DBI.pm'}=__FILE__;
sub native_1073 {
    my ($raise)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB1073::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER,name TEXT)');
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#else')});
    $db->do('CREATE TABLE BADWORDS(id_channel INTEGER,badword TEXT)');
    $db->do(q{INSERT INTO BADWORDS VALUES(1,'BLOCKED'),(1,'oldextra'),(2,'foreign')});
    my $bot=MB881OutputFixture::new_bot();$bot->{dbh}=$db;
    return ($bot,$db);
}
MB881OutputFixture::with_policy(sub {
    for my $entry ([\&privmsg,'PRIVMSG'],[\&action,'ACTION']) {
        my ($send,$kind)=@$entry;
        for my $raise (0,1) {
            my (@actual,@expected);
            for my $fault (qw(prepare execute fetch_first fetch_after_one)) {
                my ($bot,$db)=native_1073($raise);
                $send->($bot,'#test','warmup');
                my $old=$bot->{_badword_cache}{'#test'};
                $old->{ts}-=301;my $expired=$old->{ts};
                $db->do(q{DELETE FROM BADWORDS WHERE id_channel=1});
                $db->do(q{INSERT INTO BADWORDS VALUES(1,'partial'),(1,'newonly')});
                $bot->{irc}{wire}=[];$bot->{events}=[];$bot->{logger}{rows}=[];
                my $finished=$db->{private_finishes}//0;
                $db->{private_fault}=$fault;
                my $ok=eval {$send->($bot,'#test','blocked');1};
                my $current=$bot->{_badword_cache}{'#test'};
                my $failed=[
                    $ok?1:0,scalar @{$bot->{irc}{wire}},
                    scalar(grep {$_->[0] eq 'history'} @{$bot->{events}}),
                    scalar(grep {$_->[1]=~/\[LIVE\]/} @{$bot->{logger}{rows}}),
                    refaddr($current)==refaddr($old)?1:0,$current->{ts}==$expired?1:0,
                    [sort @{$current->{words}}],$bot->{metrics}{counts}{mediabot_db_query_errors_total}//0,
                    ($db->{private_finishes}//0)-$finished,
                    scalar(grep {$_->[1]=~/private badword/} @{$bot->{logger}{rows}})];
                $db->{private_fault}='';
                $ok=eval {$send->($bot,'#test','newonly');$send->($bot,'#test','blocked');1};
                my $recovered=$bot->{_badword_cache}{'#test'};
                push @actual,[$fault,$failed,$ok?1:0,scalar @{$bot->{irc}{wire}},
                    [sort @{$recovered->{words}}],$recovered->{ts}>$expired?1:0,$db->{private_bind}];
                push @expected,[$fault,[1,0,0,0,1,1,['blocked','oldextra'],1,$fault eq 'prepare'?0:1,0],
                    1,1,['newonly','partial'],1,['#test']];
                $db->disconnect;
            }
            is_deeply(\@actual,\@expected,
                "$kind RaiseError=$raise: failed/partial refresh retains confirmed rules and age, cleans up and retries successfully");
        }
        my ($bot,$db)=native_1073(1);
        $send->($bot,'#test','warmup');$bot->{_badword_cache}{'#test'}{ts}-=301;
        $db->do(q{DELETE FROM BADWORDS WHERE id_channel=1});
        $send->($bot,'#test','blocked');$send->($bot,'#test','foreign');
        is_deeply([scalar @{$bot->{irc}{wire}},$bot->{_badword_cache}{'#test'}{words},
            $db->{private_reads},$db->{private_finishes},$db->{private_bind}],
            [3,[],2,2,['#test']],
            "$kind: a confirmed empty result replaces old rules and is reused without importing another channel's rules");
        $db->disconnect;
    }
    for my $raise (0,1) {
        my (@actual,@expected);
        for my $send (\&privmsg,\&action) {
            my ($bot,$db)=native_1073($raise);$db->{private_fault}='fetch_first';
            my $ok=eval {$send->($bot,'#test','legacy fallback');1};
            my $initial=[$ok?1:0,scalar @{$bot->{irc}{wire}},
                exists($bot->{_badword_cache}{'#test'})?1:0,
                $bot->{metrics}{counts}{mediabot_db_query_errors_total}//0,$db->{private_finishes}//0];
            $db->{private_fault}='';$send->($bot,'#test','blocked');
            push @actual,[$initial,scalar @{$bot->{irc}{wire}},
                [sort @{$bot->{_badword_cache}{'#test'}{words}}],$db->{private_finishes}];
            push @expected,[[1,1,0,1,1],1,['blocked','oldextra'],2];
            $db->disconnect;
        }
        is_deeply(\@actual,\@expected,
            "RaiseError=$raise: initial fetch failure retains legacy send behavior but cannot suppress the next real read");
    }
});
is_deeply(\@warnings_1073,[],'native badword reads and output paths are warning-free');
done_testing;
