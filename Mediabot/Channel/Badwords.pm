package Mediabot::Channel::Badwords;
use strict;
use warnings;

# Complete read only. Cache age, diagnostics and fallback belong to the caller.
# Keep read success independent of finish(), including driver error clearing.
sub read {
    my ($dbh, $target) = @_;
    my ($sth, @words);
    my $complete = eval {
        $sth = $dbh->prepare(
            "SELECT badword FROM CHANNEL"
            . " JOIN BADWORDS ON BADWORDS.id_channel = CHANNEL.id_channel"
            . " WHERE CHANNEL.name = ?"
        ) or die "badword_prepare\n";
        $sth->execute($target) or die "badword_execute\n";
        while (my $row = $sth->fetchrow_hashref) {
            die "badword_row\n" unless ref($row) eq 'HASH';
            next unless defined $row->{badword};
            die "badword_value\n" if ref($row->{badword});
            push @words, lc($row->{badword});
        }
        die "badword_fetch\n" if $sth->err;
        1;
    };
    # Capture success before finish(), which may clear a driver's error flag.
    eval { $sth->finish } if $sth;
    return $complete ? { status => 'ok', words => \@words } : { status => 'error' };
}

# Command operations hand the statement back: fetch/finish, diagnostics, notices
# and cache invalidation have different ordering in add and remove handlers.
# Exceptions propagate and DBI truth (including 0E0) is not normalized by rows.
sub _execute_command {
    my ($dbh, $sql, @bind) = @_;
    my $sth = $dbh->prepare($sql);
    my $ok = $sth && $sth->execute(@bind);
    return { ok => $ok, statement => $sth, sql => $sql };
}
sub find_for_add {
    my ($dbh, $id_channel, $word) = @_;
    return _execute_command($dbh,
        "SELECT id_badwords, badword FROM BADWORDS WHERE id_channel=? AND badword=?",
        $id_channel, $word);
}
sub find_for_remove {
    my ($dbh, $id_channel, $word) = @_;
    return _execute_command($dbh,
        "SELECT id_badwords FROM BADWORDS WHERE id_channel = ? AND badword = ?",
        $id_channel, $word);
}
sub insert {
    my ($dbh, $id_channel, $word) = @_;
    return _execute_command($dbh,
        "INSERT INTO BADWORDS (id_channel, badword) VALUES (?, ?)", $id_channel, $word);
}
sub delete_by_id {
    my ($dbh, $id_badwords) = @_;
    return _execute_command($dbh,
        "DELETE FROM BADWORDS WHERE id_badwords = ?", $id_badwords);
}

1;
