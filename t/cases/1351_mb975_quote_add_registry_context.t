use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use File::Temp qw(tempdir);
use Scalar::Util qw(refaddr);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;

{
    package MB975::DBI; our @ISA = ('DBI');
    package MB975::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $probe = $sql =~ /SELECT QUOTES\.id_quotes FROM QUOTES JOIN CHANNEL/;
        my $sth = $db->SUPER::prepare($sql,@rest);
        $sth->{private_probe} = $probe ? 1 : 0 if $sth;
        return $sth;
    }
    package MB975::DBI::st; our @ISA = ('DBI::st');
    sub fetchrow_hashref {
        my ($sth) = @_;
        return $sth->set_err(1,'private alias lookup detail')
            if $sth->{private_probe} && $sth->{Database}{private_fail_probe};
        return $sth->SUPER::fetchrow_hashref;
    }
    package MB975::Channel; sub get_id {1}
    package MB975::Log; sub log {1}
    package MB975::Achievements;
    sub check_community_contributions {push @{$_[0]{calls}},[@_[1..3]];1}
}
$INC{'MB975/DBI.pm'} = __FILE__;
my $tmp = tempdir(CLEANUP=>1);
my $serial = 0;
my (@wire,@warnings,@logs);
no warnings qw(redefine once);
my $notice = sub {push @wire,['notice',$_[1],$_[2]];1};
my $public = sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Quotes::botNotice = $notice;
local *Mediabot::Quotes::botPrivmsg = $public;
local *Mediabot::botNotice = $notice;
local *Mediabot::botPrivmsg = $public;
local *Mediabot::Quotes::logBot = sub {push @logs,[@_[1..$#_]];1};
local *Mediabot::getUserChannelLevel = sub {0};
local $SIG{__WARN__} = sub {push @warnings,@_};

sub setup_1351 {
    my ($raise) = @_;
    my $dsn = 'dbi:SQLite:dbname='.$tmp.'/'.++$serial.'.sqlite';
    my $db = DBI->connect($dsn,'','',{RootClass=>'MB975::DBI',
        RaiseError=>$raise,PrintError=>0,AutoCommit=>1,sqlite_unicode=>1});
    my $peer = DBI->connect($dsn,'','',{RaiseError=>1,PrintError=>0,
        AutoCommit=>1,sqlite_unicode=>1});
    $peer->do('PRAGMA foreign_keys=ON'); $db->do('PRAGMA foreign_keys=ON');
    $peer->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    $peer->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)');
    $peer->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY AUTOINCREMENT,
        id_channel INTEGER REFERENCES CHANNEL(id_channel),
        id_user INTEGER REFERENCES USER(id_user),quotetext TEXT,hits INTEGER DEFAULT 0)});
    $peer->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $peer->do(q{INSERT INTO USER VALUES(7,'Account')});
    $peer->do(q{INSERT INTO QUOTES(id_quotes,id_channel,id_user,quotetext)
        VALUES(10,1,7,'Existing quote'),(20,2,7,'Other channel')});
    my $bot = Mediabot->new({dbh=>$db});
    $bot->{channels}{'#test'} = bless {},'MB975::Channel';
    $bot->{logger} = bless {},'MB975::Log';
    $bot->{achievements} = bless {calls=>[]},'MB975::Achievements';
    return ($bot,$db,$peer);
}
sub user_1351 {
    my ($kind) = @_;
    return undef if $kind eq 'guest';
    my $user = Mediabot::User->new({id_user=>7,nickname=>'Account',
        auth=>$kind eq 'authenticated'?1:0});
    $user->{level}='User'; $user->{level_desc}='User';
    return $user;
}
sub invoke_1351 {
    my ($bot,$name,$kind,@args) = @_;
    @wire=(); @warnings=(); @logs=();
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Speaker',channel=>'#test',
        command=>$name,args=>[@args]);
    $ctx->{user} = user_1351($kind); $ctx->{_user_fetched}=1;
    my $handler = $bot->command_registry->handler_for($name,'public');
    my $ok = eval {$handler->($ctx);1};
    return ($ok?'':$@,$ctx);
}
sub visible_wire_1351 {
    return [map {
        my @message=@$_;
        $message[2] =~ s/[\x02\x0f]//g if defined $message[2];
        \@message;
    } @wire];
}

for my $raise (0,1) {
    for my $kind (qw(guest logged_out authenticated)) {
        for my $name (qw(q quote)) {
            for my $subcommand (qw(add ADD)) {
                my ($bot,$db,$peer)=setup_1351($raise);
                my $label="$name $subcommand $kind RaiseError=$raise";
                my @args=($subcommand,'Un été','à Poudlard','🦉');
                my ($error,$ctx)=invoke_1351($bot,$name,$kind,@args);
                is($error,'',"$label: real registry handler completes");
                my $row=$peer->selectrow_hashref(q{SELECT * FROM QUOTES
                    WHERE id_channel=1 AND quotetext=?},undef,'Un été à Poudlard 🦉');
                ok($row && $row->{id_quotes}>20,"$label: quote is actually persisted in the caller's channel");
                is($row?$row->{id_user}:undef,$kind eq 'authenticated'?7:undef,
                    "$label: only authenticated caller receives author attribution");
                my $id=$row?$row->{id_quotes}:0;
                my $prefix=$kind eq 'authenticated'?'(Account) ':'';
                is_deeply(visible_wire_1351(),[['public','#test',$prefix."done. (id: $id)"]],
                    "$label: public confirmation uses the actual inserted id");
                is_deeply($ctx->args,\@args,"$label: dispatcher retains the original arguments");
                is($ctx->command,$name,"$label: original command identity is retained");
                is_deeply($bot->{achievements}{calls},[['Speaker','#test',$kind eq 'authenticated'?7:undef]],
                    "$label: one contribution for the actual actor and channel");
                is(scalar @logs,1,"$label: one native command log after successful add");
                is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES'),3,
                    "$label: one insert, no duplicate execution");
                is(scalar @warnings,0,"$label: no warning from missing or shifted arguments");
                ($error)=invoke_1351($bot,$name,$kind,@args);
                is($error,'',"$label: repeated text goes through existing duplicate detection");
                is_deeply(\@wire,[['public','#test',"Quote (id: $id) already exists"]],
                    "$label: duplicate response is correctly scoped");
                is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES'),3,
                    "$label: repeated text creates no second quote");
                is(scalar @{$bot->{achievements}{calls}},1,
                    "$label: duplicate receives no additional contribution");
                is($peer->selectrow_array('SELECT quotetext FROM QUOTES WHERE id_quotes=20'),
                    'Other channel',"$label: another channel's quote is intact");
            }
        }
    }
}

for my $raise (0,1) {
    for my $name (qw(q quote)) {
        for my $case (
            [[], 'q [add or a] text1 | text2 | ... | textn'],
            [['x'x513], 'Quote text too long (max 512 chars).'],
        ) {
            my ($bot,$db,$peer)=setup_1351($raise);
            my ($error,$ctx)=invoke_1351($bot,$name,'guest','add',@{$case->[0]});
            is($error,'',"$name invalid text: registry call completes");
            is_deeply(\@wire,[['notice','Speaker',$case->[1]]],
                "$name invalid text: existing syntax/limit notice reaches the actual caller");
            is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES'),2,
                "$name invalid text: no insertion");
            is_deeply($ctx->args,['add',@{$case->[0]}],"$name invalid text: arguments remain available");
        }
        my ($bot,$db,$peer)=setup_1351($raise);
        $db->{private_fail_probe}=1;
        my ($error)=invoke_1351($bot,$name,'guest','add','New quote');
        is($error,'',"$name RaiseError=$raise: duplicate lookup failure is contained");
        is_deeply(\@wire,[['notice','Speaker','Database error while checking quote.']],
            "$name RaiseError=$raise: alias retains the MB974 database error response");
        is($peer->selectrow_array('SELECT COUNT(*) FROM QUOTES'),2,
            "$name RaiseError=$raise: failed lookup never writes a quote");
    }
}

# Exercise the actual reversible plugin bridge, including native fallbacks.
for my $raise (0,1) {
    for my $kind (qw(guest authenticated)) {
        my ($bot,$db,$peer)=setup_1351($raise);
        my $manager=$bot->plugin_manager;
        my $native=$bot->command_registry->handler_for('quote','public');
        $manager->load_package_v3('quotes-v3',grants=>[
            qw(data.quotes.read data.quotes.write irc.reply irc.notice)]);
        for my $mode (qw(disabled off observe on unloaded)) {
            if ($mode eq 'off') {
                $manager->set_v3_channel_policy('quotes-v3','#test',mode=>'off');
                $manager->enable('quotes-v3');
            } elsif ($mode eq 'unloaded') {
                $manager->unregister_plugin('quotes-v3');
                is(refaddr($bot->command_registry->handler_for('quote','public')),refaddr($native),
                    'unload restores the exact native handler');
            } elsif ($mode ne 'disabled') {
                $manager->set_v3_channel_policy('quotes-v3','#test',mode=>$mode);
            }
            my $text="Bridge $mode $kind";
            my $label="bridge $mode $kind RaiseError=$raise";
            my ($error,$ctx)=invoke_1351($bot,'quote',$kind,'add',$text);
            is($error,'',"$label: real registered command completes");
            is($peer->selectrow_array(q{SELECT COUNT(*) FROM QUOTES
                WHERE id_channel=1 AND quotetext=?},undef,$text),1,
                "$label: exactly one actual insertion");
            my $row=$peer->selectrow_hashref(q{SELECT * FROM QUOTES WHERE quotetext=?},undef,$text);
            is($row?$row->{id_user}:undef,$kind eq 'authenticated'?7:undef,
                "$label: author identity survives the route");
            is(scalar @wire,1,"$label: one public acknowledgement");
            is($wire[0][1],'#test',"$label: response stays in the original channel");
            like($wire[0][2]//'',qr/done\. \(id:/,"$label: normal successful response");
            is_deeply($ctx->args,['add',$text],"$label: original context survives dispatch/fallback");
            is(scalar @warnings,0,"$label: no warning escapes");
        }
    }
}
done_testing;
