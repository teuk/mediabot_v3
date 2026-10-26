use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use JSON::PP ();
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

{
    package MB965::DBI; our @ISA = ('DBI');
    package MB965::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        my $kind = $sql =~ /^SELECT id_note, text FROM NOTE/ ? 'read'
            : $sql =~ /^INSERT INTO NOTE/ ? 'insert'
            : $sql =~ /^DELETE FROM NOTE/ ? 'delete' : '';
        push @{$db->{private_mb965_queries}}, $kind if length $kind;
        my $actual = $sql;
        $actual = 'SELECT * FROM mb965_missing_table'
            if length($kind) && ($db->{private_mb965_fault} // '') eq "$kind.prepare";
        my $sth = $db->SUPER::prepare($actual, @rest);
        if ($sth) {
            $sth->{private_mb965_kind} = $kind;
            $sth->{private_mb965_fetched} = 0;
        }
        return $sth;
    }
    sub last_insert_id {
        my ($db, @args) = @_;
        return undef if ($db->{private_mb965_fault} // '') eq 'identity.missing';
        return $db->set_err(1, 'private note identity failure')
            if ($db->{private_mb965_fault} // '') eq 'identity.error';
        return $db->SUPER::last_insert_id(@args);
    }
    package MB965::DBI::st; our @ISA = ('DBI::st');
    sub execute {
        my ($sth, @args) = @_;
        my $kind = $sth->{private_mb965_kind} // '';
        my $fault = $sth->{Database}{private_mb965_fault} // '';
        return $sth->set_err(1, 'private note execute failure')
            if length($kind) && $fault eq "$kind.execute";
        my $ret = $sth->SUPER::execute(@args);
        return $sth->set_err(1, 'private note acknowledgement lost')
            if length($kind) && $fault eq "$kind.ack_lost";
        return $ret;
    }
    sub fetchrow_hashref {
        my ($sth) = @_;
        my $kind = $sth->{private_mb965_kind} // '';
        my $fault = $sth->{Database}{private_mb965_fault} // '';
        my $n = $sth->{private_mb965_fetched}++;
        return $sth->set_err(1, 'private note fetch failure')
            if $kind eq 'read' && ($fault eq 'read.fetch' || ($fault eq 'read.partial' && $n > 0));
        return $sth->SUPER::fetchrow_hashref;
    }
    sub rows {
        my ($sth) = @_;
        my $kind = $sth->{private_mb965_kind} // '';
        return $sth->set_err(1, 'private note affected-row failure')
            if length($kind) && ($sth->{Database}{private_mb965_fault} // '') eq "$kind.rows";
        return $sth->SUPER::rows;
    }
    package MB965::Log;
    sub log { push @{$_[0]{lines}}, $_[2]; 1 }
}
$INC{'MB965/DBI.pm'} = __FILE__;
my (@wire, @warnings);
no warnings qw(redefine once);
local *Mediabot::UserCommands::botNotice = sub { push @wire, [@_[1,2]]; 1 };
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub copy_1341 { JSON::PP->new->decode(JSON::PP->new->encode($_[0])) }
sub setup_1341 {
    my (%args) = @_;
    @wire = (); @warnings = ();
    my $db = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', {
        RootClass => 'MB965::DBI', RaiseError => $args{raise}, PrintError => 0,
        AutoCommit => 1, sqlite_unicode => 1 });
    $db->do('CREATE TABLE NOTE(id_note INTEGER PRIMARY KEY AUTOINCREMENT, nick TEXT, text TEXT)');
    for my $i (1 .. ($args{count} // 2)) {
        $db->do('INSERT INTO NOTE VALUES(?,?,?)', undef, $i*10, 'alice', "Note café $i");
    }
    $db->do(q{INSERT INTO NOTE VALUES(900,'bob','Other user')});
    my $bot = bless { dbh => $db, logger => bless({lines=>[]}, 'MB965::Log') }, 'Mediabot';
    $bot->{_notes}{alice} = $db->selectall_arrayref(
        q{SELECT id_note AS id,text FROM NOTE WHERE nick='alice' ORDER BY id_note}, {Slice=>{}})
        if $args{warm};
    $db->{private_mb965_queries} = [];
    return ($bot, $db);
}
sub invoke_1341 {
    my ($entry, $bot, $method, @args) = @_;
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Alice',channel=>'#test',args=>\@args);
    no strict 'refs';
    my $ok = eval { &{ $entry . '::' . $method }($ctx); 1 };
    return $ok ? '' : $@;
}
sub rows_1341 {
    $_[0]->selectall_arrayref('SELECT id_note,nick,text FROM NOTE ORDER BY id_note')
}
sub notices_1341 { join(' ', map { $_->[1] } @wire) }

for my $entry (qw(Mediabot::CommunityState Mediabot::UserCommands Mediabot)) {
    for my $raise (0,1) {
        for my $fault (qw(read.prepare read.execute read.fetch read.partial)) {
            for my $op (qw(add list export search delete)) {
                my ($bot,$db) = setup_1341(raise=>$raise,count=>10);
                my $before = rows_1341($db);
                $db->{private_mb965_fault} = $fault;
                my ($method,@args) = $op eq 'add' ? ('mbNote_ctx','New note')
                    : $op eq 'export' ? ('mbNote_ctx','export')
                    : $op eq 'search' ? ('mbNote_ctx','search','café')
                    : $op eq 'delete' ? ('mbNotes_ctx','del','1') : ('mbNotes_ctx');
                my $label = "$entry RaiseError=$raise $fault $op";
                is(invoke_1341($entry,$bot,$method,@args), '', "$label: exception stays inside the command");
                is_deeply(rows_1341($db), $before, "$label: no note is written or removed after an unconfirmed load");
                is_deeply($bot->{_notes}{alice}//[], [], "$label: partial read is never published to the cache");
                like(notices_1341(), qr/database error/i, "$label: failure is reported privately");
                unlike(notices_1341(), qr/Note saved|Note deleted|No notes|Note café|private note|mb965_missing/,
                    "$label: no false success, false empty list, partial content or raw error");
                is(scalar @warnings, 0, "$label: no warnings escape");
                $db->{private_mb965_fault} = '';
                @wire = ();
                invoke_1341($entry,$bot,'mbNotes_ctx');
                is(scalar @{$bot->{_notes}{alice}}, 10, "$label: a healthy retry loads all ten original notes");
            }
        }

        for my $warm (0,1) {
            for my $kind (qw(insert delete)) {
                for my $stage (qw(prepare execute ack_lost rows)) {
                    my ($bot,$db) = setup_1341(raise=>$raise,warm=>$warm);
                    invoke_1341($entry,$bot,'mbNotes_ctx');
                    my $cache = copy_1341($bot->{_notes}{alice});
                    my $before = rows_1341($db);
                    $db->{private_mb965_fault} = "$kind.$stage";
                    @wire = ();
                    my ($method,@args) = $kind eq 'insert' ? ('mbNote_ctx','A new café')
                        : ('mbNotes_ctx','del','2');
                    my $label = "$entry RaiseError=$raise warm=$warm $kind.$stage";
                    is(invoke_1341($entry,$bot,$method,@args), '', "$label: command contains the write error");
                    is_deeply($bot->{_notes}{alice}, $cache, "$label: unconfirmed write does not mutate the displayed cache");
                    unlike(notices_1341(), qr/Note saved|Note deleted|private note/, "$label: no false success or raw exception");
                    like(notices_1341(), qr/could not confirm/i, "$label: uncertain outcome asks the user to check notes");
                    if ($stage eq 'prepare' || $stage eq 'execute') {
                        is_deeply(rows_1341($db), $before, "$label: failed SQL preserves every persisted note");
                    } else {
                        is(scalar @{rows_1341($db)}, $kind eq 'insert' ? 4 : 2,
                            "$label: fixture models a committed write whose acknowledgement was lost");
                    }
                    $db->{private_mb965_fault} = '';
                    @wire = ();
                    invoke_1341($entry,$bot,'mbNotes_ctx');
                    my $expected = $db->selectall_arrayref(
                        q{SELECT id_note AS id,text FROM NOTE WHERE nick='alice' ORDER BY id_note}, {Slice=>{}});
                    is_deeply($bot->{_notes}{alice}, $expected, "$label: next list reconciles cache with committed state");
                    is($db->selectrow_array(q{SELECT text FROM NOTE WHERE nick='bob'}), 'Other user', "$label: other user's note survives");
                    is(scalar @warnings, 0, "$label: no warnings escape");
                }
            }
        }

        for my $fault (qw(identity.missing identity.error)) {
            my ($bot,$db) = setup_1341(raise=>$raise,warm=>1);
            my $cache = copy_1341($bot->{_notes}{alice});
            $db->{private_mb965_fault} = $fault;
            my $label = "$entry RaiseError=$raise $fault";
            is(invoke_1341($entry,$bot,'mbNote_ctx','A saved café'), '', "$label: missing insert identity is contained");
            is_deeply($bot->{_notes}{alice}, $cache, "$label: never invents a persistent id from an ordinal");
            like(notices_1341(), qr/could not confirm/i, "$label: tells the user to check before retrying");
            unlike(notices_1341(), qr/Note saved/, "$label: no unconfirmed acknowledgement");
            $db->{private_mb965_fault} = '';
            @wire = ();
            invoke_1341($entry,$bot,'mbNotes_ctx');
            is($bot->{_notes}{alice}[-1]{id}, 901, "$label: reload finds the actual stored id");
            invoke_1341($entry,$bot,'mbNotes_ctx','del','3');
            is($db->selectrow_array(q{SELECT COUNT(*) FROM NOTE WHERE nick='alice'}), 2,
                "$label: recovered ordinal deletes only the newly stored note");
        }

        {
            my ($bot,$db) = setup_1341(raise=>$raise,warm=>1);
            $db->do(q{DELETE FROM NOTE WHERE id_note=20});
            @wire = ();
            is(invoke_1341($entry,$bot,'mbNotes_ctx','del','2'), '', "$entry: zero-row delete is contained");
            unlike(notices_1341(), qr/Note deleted/, "$entry: zero-row delete is not announced as a new deletion");
            invoke_1341($entry,$bot,'mbNotes_ctx');
            is_deeply([map {$_->{id}} @{$bot->{_notes}{alice}}], [10], "$entry: stale cache refreshes after a missing row");
        }

        for my $kind (qw(insert delete)) {
            for my $op (qw(list add)) {
                my ($bot,$db) = setup_1341(raise=>$raise,warm=>1);
                my $cache = copy_1341($bot->{_notes}{alice});
                $db->{private_mb965_fault} = "$kind.ack_lost";
                $kind eq 'insert' ? invoke_1341($entry,$bot,'mbNote_ctx','Committed café')
                    : invoke_1341($entry,$bot,'mbNotes_ctx','del','2');
                my $committed = rows_1341($db);
                @wire = ();
                $db->{private_mb965_fault} = 'read.partial';
                my ($method,@args) = $op eq 'add' ? ('mbNote_ctx','Do not duplicate') : ('mbNotes_ctx');
                my $label = "$entry RaiseError=$raise $kind lost acknowledgement then failed $op reload";
                is(invoke_1341($entry,$bot,$method,@args), '', "$label: reload error is contained");
                is_deeply($bot->{_notes}{alice}, $cache, "$label: incomplete reload preserves the last complete cache");
                is_deeply(rows_1341($db), $committed, "$label: no second write while reconciliation is unavailable");
                like(notices_1341(), qr/database error/i, "$label: failed reconciliation is explicit");
                unlike(notices_1341(), qr/Note café|Note saved|No notes/, "$label: stale contents are not presented as current");
                $db->{private_mb965_fault} = '';
                @wire = ();
                invoke_1341($entry,$bot,'mbNotes_ctx');
                is(scalar @{$bot->{_notes}{alice}}, $kind eq 'insert' ? 3 : 1,
                    "$label: healthy retry reconciles the committed result");
            }
        }

        {
            my ($bot,$db) = setup_1341(raise=>$raise,count=>0);
            is(invoke_1341($entry,$bot,'mbNotes_ctx'), '', "$entry: empty successful read is handled");
            like(notices_1341(), qr/No notes\./, "$entry: confirmed empty list remains distinct from a read failure");
            invoke_1341($entry,$bot,'mbNote_ctx',('é' x 200));
            is(length($db->selectrow_array(q{SELECT text FROM NOTE WHERE nick='alice'})), 200,
                "$entry: a 200-character Unicode note still persists");
            invoke_1341($entry,$bot,'mbNote_ctx',('é' x 201));
            is($db->selectrow_array(q{SELECT COUNT(*) FROM NOTE WHERE nick='alice'}), 1,
                "$entry: oversized note still cannot reach INSERT");
        }

        {
            my ($bot,$db) = setup_1341(raise=>$raise);
            is(invoke_1341($entry,$bot,'mbNote_ctx','A healthy café'), '', "$entry: ordinary save completes");
            like(notices_1341(), qr/Note saved \(#3 total\)/, "$entry: confirmed save keeps its normal acknowledgement");
            is($bot->{_notes}{alice}[2]{id}, 901, "$entry: cache uses the actual non-contiguous database id");
            @wire = ();
            invoke_1341($entry,$bot,'mbNote_ctx','search','healthy');
            like(notices_1341(), qr/\[3\] A healthy café/, "$entry: search reports the full-list ordinal");
            invoke_1341($entry,$bot,'mbNotes_ctx','del','3');
            like($wire[-1][1], qr/^Note deleted\./, "$entry: confirmed delete keeps its normal acknowledgement");
            is($db->selectrow_array(q{SELECT COUNT(*) FROM NOTE WHERE nick='alice'}), 2, "$entry: healthy add/delete preserves the previous notes");
        }
    }
}
done_testing;
