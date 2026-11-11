package Mediabot::Channel::FloodRules;
use strict;
use warnings;

# CHANNEL_FLOOD boundary. Receives only a DBI-compatible handle and
# channel identity/values; owns no bot, cache, clock, logger or transport.
# Distinguish an absent row from a false prepare/execute result. DBI exceptions
# propagate unchanged. Preserve the existing statement call order and failure
# semantics; the admission policy owns defaults, caching and fail-open choices.
sub read {
    my ($dbh, $id_channel) = @_;
    my $sth = $dbh->prepare(
        "SELECT nbmsg_max, duration, timetowait FROM CHANNEL_FLOOD WHERE id_channel = ?"
    );
    if ($sth && $sth->execute($id_channel)) {
        my $row = $sth->fetchrow_hashref;
        $sth->finish;
        return $row ? { status => 'found', row => $row } : { status => 'missing' };
    }
    no warnings 'once';
    return { status => 'error', error => $DBI::errstr };
}

# Operator display uses the historical name-based JOIN, not admission's ID read.
# Hand the statement back even after false execute: the command logs before
# finish on error, and sends its notice before finish on success. Fetch and DBI
# exceptions retain their original identity; no finish is added on thrown work.
sub read_for_display {
    my ($dbh, $channel_name) = @_;
    my $sth = $dbh->prepare(q{
            SELECT CHANNEL_FLOOD.nbmsg_max,
                   CHANNEL_FLOOD.duration,
                   CHANNEL_FLOOD.timetowait
            FROM CHANNEL
            JOIN CHANNEL_FLOOD ON CHANNEL.id_channel = CHANNEL_FLOOD.id_channel
            WHERE CHANNEL.name = ?
        });
    unless ($sth && $sth->execute($channel_name)) {
        return { status => 'error', statement => $sth };
    }
    my $row = $sth->fetchrow_hashref();
    return { status => $row ? 'found' : 'missing', row => $row, statement => $sth };
}

# Execute an UPDATE without owning command diagnostics or statement retirement.
# Return the statement to the caller: historical execute failure is logged BEFORE
# finish, while successful finish precedes cache invalidation and the IRC reply.
# Do not normalize DBI truth (notably 0E0) or catch/replace exception objects.
sub write {
    my ($dbh, $id_channel, $max_msg, $period_sec, $wait_sec) = @_;
    my $sth = $dbh->prepare(q{
        UPDATE CHANNEL_FLOOD
        SET nbmsg_max = ?, duration = ?, timetowait = ?
        WHERE id_channel = ?
    });
    return { status => 'prepare_error' } unless $sth;
    my $ok = $sth->execute($max_msg, $period_sec, $wait_sec, $id_channel);
    return { status => $ok ? 'updated' : 'execute_error', statement => $sth };
}

1;
