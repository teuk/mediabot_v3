package Mediabot::Channel::FloodRules;
use strict;
use warnings;

# CHANNEL_FLOOD boundary. Receives only a DBI-compatible handle and
# channel ID; owns no bot, cache, clock, logger or transport.
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
