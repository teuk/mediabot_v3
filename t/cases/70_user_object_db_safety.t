# t/cases/70_user_object_db_safety.t
# =============================================================================
# Native role-read regressions and existing create-path contracts.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use DBI;
use JSON::PP ();
use Mediabot::User;
{
    package MB1077::DBI;our @ISA=('DBI');
    package MB1077::DBI::db;our @ISA=('DBI::db');
    sub prepare {
        my ($db,$sql,@rest)=@_;
        return $db->set_err(1701,'private role detail: prepare')
            if ($db->{private_fault}//'') eq 'prepare';
        return $db->SUPER::prepare($sql,@rest);
    }
    package MB1077::DBI::st;our @ISA=('DBI::st');
    sub execute {
        my ($sth,@bind)=@_;
        $sth->{Database}{private_bind}=\@bind;
        return $sth->set_err(1702,'private role detail: execute')
            if ($sth->{Database}{private_fault}//'') eq 'execute';
        return $sth->SUPER::execute(@bind);
    }
    sub fetchrow_hashref {
        my ($sth,@rest)=@_;my $fault=$sth->{Database}{private_fault}//'';
        return $sth->set_err(1703,'private role detail: fetch') if $fault eq 'fetch_first';
        my $row=$sth->SUPER::fetchrow_hashref(@rest);
        $sth->set_err(1704,'private role detail: returned row') if $fault eq 'fetch_with_row';
        return $row;
    }
    sub finish {
        my ($sth)=@_;my $db=$sth->{Database};
        $db->{private_finished}++;
        $db->{private_on_finish}->() if $db->{private_on_finish};
        local $sth->{RaiseError}=0;$sth->set_err(undef,undef);
        my $rv=$sth->SUPER::finish;
        die "private role cleanup detail\n" if $db->{private_finish_die};
        return $rv;
    }
}
$INC{'MB1077/DBI.pm'}=__FILE__;

sub _slurp_user_object_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_user_object_safety {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src    = _slurp_user_object_safety(File::Spec->catfile('.', 'Mediabot', 'User.pm'));
    my $create = _extract_sub_user_object_safety($src, 'create');

    $assert->ok(
        $src =~ /sub _log/,
        'User.pm has _log helper'
    );

    # MB1077: exercise the real User role reader over SQLite, including DBI
    # false-return and RaiseError paths. No duplicate role-reading algorithm.
    my $json = JSON::PP->new->canonical;
    my $deep = sub {my ($got,$want,$name)=@_;$assert->is($json->encode($got),$json->encode($want),$name)};
    my $setup = sub {
        my ($raise)=@_;
        my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',
            {RootClass=>'MB1077::DBI',RaiseError=>$raise,PrintError=>0,AutoCommit=>1});
        $db->do('CREATE TABLE USER_LEVEL(id_user_level INTEGER PRIMARY KEY,level INTEGER,description TEXT)');
        $db->do('INSERT INTO USER_LEVEL VALUES(?,?,?)',undef,@$_) for
            [1,0,'Owner'],[2,1,'Master'],[3,2,'Administrator'],[4,3,'User'];
        my $u=Mediabot::User->new({id_user=>17,nickname=>'Teuk',id_user_level=>1,auth=>1,dbh=>$db});
        return ($u,$db);
    };
    my $authority=sub {
        my ($u)=@_;
        return [$u->level,$u->level_description,map {$u->has_level($_)?1:0} qw(Owner Master Administrator User)];
    };
    {
        my ($u,$db)=$setup->(1);my @got;
        for my $id (1..4) {
            $u->{level_id}=$id;
            push @got,[$u->load_level?1:0,$authority->($u),$db->{private_bind}];
        }
        my (undef,$other)=$setup->(1);
        $other->do("UPDATE USER_LEVEL SET level=0,description='Owner' WHERE id_user_level=4");
        push @got,[$u->load_level($other)?1:0,$authority->($u),$other->{private_bind}];
        $deep->(\@got,[[1,[0,'Owner',1,1,1,1],[1]], [1,[1,'Master',0,1,1,1],[2]],
            [1,[2,'Administrator',0,0,1,1],[3]], [1,[3,'User',0,0,0,1],[4]],
            [1,[0,'Owner',1,1,1,1],[4]]],
            'native role reads keep all four ranks, zero level, bound IDs, stored DBH and explicit DBH override');
        $db->disconnect;$other->disconnect;
    }
    {
        my (@got,@want);
        for my $raise (0,1) {
            for my $fault (qw(prepare execute fetch_first fetch_with_row)) {
                my ($u,$db)=$setup->($raise);$u->load_level;
                $db->{private_fault}=$fault;$db->{private_finished}=0;
                my (@warnings,$rv);local $SIG{__WARN__}=sub {push @warnings,@_};
                my $ok=eval {$rv=$u->load_level;1};
                my $diag=join('',@warnings);
                push @got,[$raise,$fault,$ok?1:0,$rv,$authority->($u),$u->is_authenticated,
                    $db->{private_finished},scalar(@warnings),
                    $diag=~/load_level\(\) SQL (?:prepare|execute|fetch) error/?1:0,
                    $diag=~/private role detail/?1:0];
                push @want,[$raise,$fault,1,0,[undef,undef,0,0,0,0],1,
                    $fault eq 'prepare'?0:1,1,1,0];
                $db->disconnect;
            }
        }
        $deep->(\@got,\@want,
            'native prepare/execute/fetch faults revoke old authority, contain RaiseError, clean up and emit only bounded stage diagnostics');
    }
    {
        my (@got,@want);
        for my $case (qw(absent no_db no_level_id)) {
            my ($u,$db)=$setup->(1);$u->load_level;$db->{private_finished}=0;
            $db->do('DELETE FROM USER_LEVEL WHERE id_user_level=1') if $case eq 'absent';
            $u->set_dbh(undef) if $case eq 'no_db';
            $u->{level_id}=undef if $case eq 'no_level_id';
            my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
            my $rv=$u->load_level;
            push @got,[$case,$rv,$authority->($u),$u->id,$u->nickname,$u->is_authenticated,
                scalar @warnings,$db->{private_finished}];
            push @want,[$case,0,[undef,undef,0,0,0,0],17,'Teuk',1,0,$case eq 'absent'?1:0];
            $db->disconnect;
        }
        $deep->(\@got,\@want,
            'deleted roles and missing prerequisites remove cached authority without changing identity/authentication or reporting absence as SQL failure');
    }
    {
        my ($u,$db)=$setup->(1);$u->load_level;
        $db->{private_fault}='fetch_first';my @warnings;local $SIG{__WARN__}=sub {push @warnings,@_};
        my $failed;my $failed_ok=eval {$failed=$u->load_level;1};my $empty=$authority->($u);
        $db->{private_fault}='';$db->do("UPDATE USER_LEVEL SET level=3,description='User' WHERE id_user_level=1");
        my $recovered=$u->load_level;
        $deep->([$failed_ok?1:0,$failed,$empty,$recovered,$authority->($u),$u->is_authenticated],
            [1,0,[undef,undef,0,0,0,0],1,[3,'User',0,0,0,1],1],
            'the same authenticated object recovers from a failed refresh using its current downgraded role');
        $db->disconnect;
    }
    {
        my (@got,@want);
        for my $fault ('','fetch_first') {
            my ($u,$db)=$setup->(1);$u->load_level;
            $db->{private_fault}=$fault;$db->{private_finished}=0;$db->{private_finish_die}=1;
            my @during;$db->{private_on_finish}=sub {push @during,$authority->($u)};
            my (@warnings,$rv);local $SIG{__WARN__}=sub {push @warnings,@_};
            my $ok=eval {$rv=$u->load_level;1};
            delete $db->{private_on_finish};delete $db->{private_finish_die};
            push @got,[$fault,$ok?1:0,$rv,\@during,$authority->($u),$db->{private_finished},scalar @warnings];
            push @want,[$fault,1,$fault?0:1,[[undef,undef,0,0,0,0]],
                $fault?[undef,undef,0,0,0,0]:[0,'Owner',1,1,1,1],1,$fault?1:0];
            $db->disconnect;
        }
        $deep->(\@got,\@want,
            'cleanup runs before publishing authority; cleanup exceptions cannot revive a failed read or discard a confirmed one');
    }

    $assert->ok(!grep({index($create, $_) < 0} ('level SQL prepare error', 'duplicate-check SQL prepare error', 'user insert SQL prepare error', 'hostmask SQL prepare error', 'refetch SQL prepare error')),
        'create retains guards for all five prepare failures');

    $assert->ok(!grep({index($create, $_) < 0} ('level SQL execute error', 'duplicate-check SQL execute error', 'Failed to insert user', 'Failed to insert hostmask', 'refetch SQL execute error')),
        'create retains guards for all five execute failures');

    $assert->ok(
        $create =~ /\$dbh->last_insert_id/,
        'create uses DB handle last_insert_id'
    );

    $assert->ok(
        $create =~ /mysql_insertid/,
        'create keeps mysql_insertid fallback'
    );

    $assert->ok(
        $create !~ /\$sth_insert->\{ Database \}->last_insert_id/,
        'create no longer uses statement Database handle for last_insert_id'
    );

    $assert->ok(
        $create =~ /\$hm->finish;/,
        'create finishes hostmask insert statement'
    );

    $assert->ok(
        $create =~ /\$sth_get->finish;\s*return undef unless \$row;/s,
        'create finishes refetch statement before row check'
    );
};
