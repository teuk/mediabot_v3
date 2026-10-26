use strict;
use warnings;
use Test::More;
use DBI;
use Mediabot::Mediabot;
use Mediabot::Context;

{
    package MB971::DBI; our @ISA = ('DBI');
    package MB971::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db,$sql,@rest) = @_;
        my $read = $sql =~ /\bSELECT\b.*\bFROM\s+FACTOID\b/is;
        $db->{private_updates}++ if $sql =~ /UPDATE FACTOID/;
        my $actual = $read && ($db->{private_fault}//'') eq 'prepare'
            ? 'SELECT * FROM mb971_missing_table' : $sql;
        my $sth = $db->SUPER::prepare($actual,@rest);
        $sth->{private_factoid_read} = $read ? 1 : 0 if $sth;
        return $sth;
    }
    package MB971::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth,@bind) = @_;
        return $sth->set_err(1,'private factoid execute detail')
            if $sth->{private_factoid_read}
                && ($sth->{Database}{private_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub _fetch_fails {
        my ($sth) = @_;
        return 0 unless $sth->{private_factoid_read};
        my $fault = $sth->{Database}{private_fault}//'';
        return $fault eq 'fetch' || ($fault eq 'partial' && ($sth->{private_delivered}//0) >= 1);
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        if ($sth->_fetch_fails) { $sth->set_err(1,'private factoid fetch detail'); return }
        my $row = $sth->SUPER::fetchrow_hashref;
        $sth->{private_delivered}++ if $row;
        return $row;
    }
    sub fetchrow_array {
        my ($sth) = @_;
        if ($sth->_fetch_fails) { $sth->set_err(1,'private factoid fetch detail'); return }
        my @row = $sth->SUPER::fetchrow_array;
        $sth->{private_delivered}++ if @row;
        return @row;
    }
    sub finish {
        my ($sth) = @_;
        $sth->{Database}{private_finished}++ if $sth->{private_factoid_read};
        my $ok = $sth->SUPER::finish;
        $sth->set_err(undef,undef);
        return $ok;
    }
    package MB971::Channel; sub get_id {1}
    package MB971::Log; sub log {1}
    package MB971::Metrics; sub inc { $_[0]{$_[2]{op}}++; 1 }
}
$INC{'MB971/DBI.pm'} = __FILE__;
my (@wire,@warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub {push @wire,['notice',$_[1],$_[2]];1};
local *Mediabot::UserCommands::botPrivmsg = sub {push @wire,['public',$_[1],$_[2]];1};
local $SIG{__WARN__} = sub {push @warnings,@_};

sub setup_1347 {
    my ($raise,$fault) = @_;
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:','','',{
        RootClass=>'MB971::DBI',RaiseError=>$raise,PrintError=>0});
    $db->sqlite_create_function('DATE_FORMAT',2,sub {substr($_[0],0,10)});
    $db->do('CREATE TABLE CHANSET_LIST(id_chanset_list INTEGER,chanset TEXT)');
    $db->do(q{CREATE TABLE FACTOID(id_channel INTEGER,keyword TEXT,value TEXT,
        created_by_nick TEXT,created_at TEXT,updated_at TEXT,hits INTEGER)});
    $db->do(q{INSERT INTO FACTOID VALUES
        (1,'word','Complete value','Author','2026-10-01','2026-10-02',3),
        (1,'word2','Second value','Other','2026-10-03','2026-10-03',1),
        (2,'word','Other channel','Other','2026-10-01','2026-10-01',99)});
    $db->{private_fault} = $fault;
    $db->{private_finished} = 0; $db->{private_updates} = 0;
    my $bot = bless {dbh=>$db,channels=>{'#test'=>bless({},'MB971::Channel')},
        logger=>bless({},'MB971::Log'),metrics=>bless({},'MB971::Metrics')},'Mediabot';
    return ($bot,$db);
}
sub invoke_1347 {
    my ($entry,$bot,$case) = @_;
    @wire=(); @warnings=();
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Reader',channel=>'#test',args=>$case->{args});
    no strict 'refs';
    my $ok = eval { &{"${entry}::mb$case->{command}_ctx"}($ctx); 1 };
    return $ok ? '' : $@;
}
my @cases = (
    {command=>'Whatis',args=>['word'],error=>'whatis: lookup failed.'},
    {command=>'Whatis',args=>['__quiet__','word'],error=>'whatis: lookup failed.',quiet=>1},
    {command=>'Factoid',args=>['word'],error=>'factoid: lookup failed.'},
    {command=>'Factoids',args=>[],error=>'factoids: listing failed.',list=>1},
    {command=>'Factoids',args=>['w*'],error=>'factoids: listing failed.',list=>1},
    {command=>'Factoids',args=>['top'],error=>'factoids: listing failed.',list=>1},
);
for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    for my $raise (0,1) {
        for my $case (@cases) {
            my $label = "$entry $case->{command} @{$case->{args}} RaiseError=$raise";
            for my $fault ('fetch', ($entry eq 'Mediabot' ? ('prepare','execute') : ()),
                    ($case->{list} ? 'partial' : ())) {
                my ($bot,$db) = setup_1347($raise,$fault);
                my $error = invoke_1347($entry,$bot,$case);
                $db->{private_fault} = '';
                is($error,'',"$label $fault: handler contains the read failure");
                is_deeply(\@wire, $case->{quiet} ? [] : [['notice','Reader',$case->{error}]],
                    "$label $fault: fixed error, no absence or partial success response");
                is($db->{private_updates},0,"$label $fault: no recall update after an unconfirmed read");
                is($bot->{metrics}{whatis}//0,0,"$label $fault: no successful recall metric");
                is($db->{private_finished},$fault eq 'prepare'?0:1,
                    "$label $fault: prepared read cursor is finished");
                is($db->selectrow_array(q{SELECT hits FROM FACTOID WHERE id_channel=1 AND keyword='word'}),
                    3,"$label $fault: stored counter is unchanged");
                is(scalar @warnings,0,"$label $fault: driver details do not escape as warnings");
            }
            my ($bot,$db) = setup_1347($raise,'');
            is(invoke_1347($entry,$bot,$case),'',"$label: healthy read succeeds");
            my $text = join(' ',map {$_->[2]} @wire);
            like($text,$case->{list}?qr/word.*word2/:qr/Complete value/,
                "$label: complete scoped result remains available");
            unlike($text,qr/Other channel|99/,"$label: another channel's data stays out of the response");
            is($db->{private_finished},1,"$label: healthy cursor is finished");
            is($db->selectrow_array(q{SELECT hits FROM FACTOID WHERE id_channel=1 AND keyword='word'}),
                $case->{command} eq 'Whatis'?4:3,"$label: existing recall-accounting behavior is retained");
            is($db->selectrow_array(q{SELECT hits FROM FACTOID WHERE id_channel=2}),99,
                "$label: other channel's counter is intact");
        }
    }
}
for my $raise (0,1) {
    for my $case (@cases) {
        my ($bot,$db) = setup_1347($raise,'');
        $db->do('DELETE FROM FACTOID WHERE id_channel=1');
        is(invoke_1347('Mediabot',$bot,$case),'',"$case->{command}: confirmed empty read completes");
        if ($case->{quiet}) {
            is_deeply(\@wire,[],"quiet absence RaiseError=$raise stays silent");
        } else {
            like(join(' ',map {$_->[2]} @wire),qr/don't know|No factoids/,
                "confirmed absence RaiseError=$raise keeps its existing message");
        }
    }
}
done_testing;
