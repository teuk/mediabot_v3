use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Time::Local qw(timegm);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::User;
use Mediabot::Plugin::QuoteServiceV3;

{
    package MB978::Log; sub log {1}
}
my (@wire,@warnings,@logs);
no warnings qw(redefine once);
local *Mediabot::Quotes::botNotice=sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::Quotes::botPrivmsg=sub {push @wire,['public',$_[1],$_[2]];1};
local *Mediabot::Quotes::logBot=sub {push @logs,[@_[1..$#_]];1};
local $SIG{__WARN__}=sub {push @warnings,@_};

sub setup_1354 {
    my ($raise,$shadow,$anonymous)=@_;
    my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RaiseError=>$raise,PrintError=>0,sqlite_unicode=>1});
    $db->do('PRAGMA foreign_keys=ON');
    $db->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY,name TEXT)');
    # The canonical schema has id_user, with no id column. The second fixture
    # deliberately supplies conflicting legacy ids to expose wrong attribution.
    $db->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT'
        .($shadow?',id INTEGER':'').')');
    $db->do(q{CREATE TABLE QUOTES(id_quotes INTEGER PRIMARY KEY,
        id_channel INTEGER REFERENCES CHANNEL(id_channel),
        id_user INTEGER REFERENCES USER(id_user),quotetext TEXT,ts TEXT,hits INTEGER DEFAULT 0)});
    $db->do(q{INSERT INTO CHANNEL VALUES(1,'#test'),(2,'#other')});
    $db->do($shadow?q{INSERT INTO USER VALUES(7,'Alice',8),(8,'Bob',7)}
        :q{INSERT INTO USER VALUES(7,'Alice'),(8,'Bob')});
    my @authors=$anonymous?(undef,undef,undef,undef,7,8):(7,7,7,8,undef,undef);
    my $id=0;
    for my $author (@authors) {
        $db->do(q{INSERT INTO QUOTES(id_quotes,id_channel,id_user,quotetext,ts)
            VALUES(?,1,?,'local','2026-10-01 12:00:00')},undef,++$id,$author);
    }
    for (1..9) {
        $db->do(q{INSERT INTO QUOTES(id_quotes,id_channel,id_user,quotetext,ts)
            VALUES(?,2,8,'foreign','2026-10-02 12:00:00')},undef,++$id);
    }
    $db->sqlite_create_function('UNIX_TIMESTAMP',1,sub {
        return undef unless defined $_[0];
        my ($y,$m,$d,$h,$min,$s)=$_[0]=~/^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
        return timegm($s,$min,$h,$d,$m-1,$y);
    });
    $db->do('PRAGMA query_only=ON');
    my $bot=Mediabot->new({dbh=>$db});
    $bot->{logger}=bless {},'MB978::Log';
    return ($bot,$db);
}
sub invoke_1354 {
    my ($entry,$bot,$channel,$auth)=@_;
    @wire=();@warnings=();@logs=();
    my $result;
    my $ok=eval {
        if ($entry eq 'registry:q') {
            my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>$channel,
                command=>'q',args=>['stats']);
            $ctx->{_user_fetched}=1;
            if ($auth) {
                $ctx->{user}=Mediabot::User->new({id_user=>7,nickname=>'Alice',auth=>1});
                $ctx->{user}{level}='User';$ctx->{user}{level_desc}='User';
            }
            $result=$bot->command_registry->handler_for('q','public')->($ctx);
        } else {
            no strict 'refs';
            $result=&{"${entry}::mbQuoteStats"}($bot,undef,'Reader',$channel);
        }
        1;
    };
    return ($ok?'':$@,$result);
}

for my $entry (qw(Mediabot::Quotes Mediabot registry:q)) {
    # Schema/author combinations are independent of DBI error mode on success.
    my $domain = $entry eq 'Mediabot::Quotes';
    for my $raise (1) {
        for my $shadow ($domain ? (0,1) : (0)) {
            for my $anonymous ($domain ? (0,1) : (0)) {
                my ($bot,$db)=setup_1354($raise,$shadow,$anonymous);
                my $label="$entry RaiseError=$raise legacy-id=$shadow anonymous-top=$anonymous";
                my ($error,$result)=invoke_1354($entry,$bot,'#test',0);
                is($error,'',"$label: statistics complete on the canonical author key");
                is($result,6,"$label: channel total includes anonymous quotes and excludes foreign quotes");
                is(scalar @wire,1,"$label: one public summary");
                is_deeply([@{$wire[0]//[]}[0,1]],['public','#test'],
                    "$label: summary stays in the requesting channel");
                my ($name,$count)=$anonymous?('Anonymous',4):('Alice',3);
                like($wire[0][2]//'',qr/\AQuotes on \#test: 6 total .* — top: \Q$name\E \($count\)\z/,
                    "$label: correct contributor and count from id_user");
                unlike($wire[0][2]//'',qr/top: Bob/,
                    "$label: conflicting legacy id and globally busier author cannot steal attribution");
                is(scalar @logs,1,"$label: existing command log is retained");
                is(scalar @warnings,0,"$label: no SQL or formatting warning escapes");

                my $v3=Mediabot::Plugin::QuoteServiceV3->new(dbh=>$db)->stats(channel=>'#test');
                is_deeply([$v3->{count},$v3->{top_author},$v3->{top_count}],[6,$name,$count],
                    "$label: native summary agrees with the existing v3 service");
                ($error)=invoke_1354($entry,$bot,'#other',0);
                is($error,'',"$label: another channel has an independent leader");
                like($wire[0][2]//'',qr/\AQuotes on \#other: 9 total .* — top: Bob \(9\)\z/,
                    "$label: author mapping remains correct in the other channel");
                ($error)=invoke_1354($entry,$bot,'#empty',0);
                is($error,'',"$label: empty channel remains valid");
                is_deeply(\@wire,[['public','#empty','Quote database is empty for #empty']],
                    "$label: existing empty-channel response is retained");
            }
        }
    }
}
for my $raise (0,1) {
    my ($bot,$db)=setup_1354($raise,0,0);
    my ($error,$result)=invoke_1354('registry:q',$bot,'#test',1);
    is($error,'',"RaiseError=$raise: authenticated public q stats uses the same corrected join");
    is($result,6,"RaiseError=$raise: authenticated caller receives the real count");
    like($wire[0][2]//'',qr/ — top: Alice \(3\)\z/,
        "RaiseError=$raise: authenticated path keeps the actual contributor");
}
done_testing;
