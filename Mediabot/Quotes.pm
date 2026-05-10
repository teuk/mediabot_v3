package Mediabot::Quotes;

# =============================================================================
# Mediabot::Quotes — Quote management commands
#
# Provides all quote-related commands and helpers:
#   mbQuotes_ctx, mbQuoteAdd, mbQuoteDel, mbQuoteView,
#   mbQuoteSearch, mbQuoteRand, mbQuoteStats, _printQuoteSyntax
#
# External dependencies (botNotice, botPrivmsg, logBot, getUserhandle)
# remain in Mediabot.pm and are called as package functions.
# =============================================================================

use strict;
use warnings;

use Exporter 'import';
use List::Util qw(min);
use Mediabot::Helpers;

our @EXPORT = qw(
    mbQuotes_ctx
    mbQuoteAdd
    mbQuoteDel
    mbQuoteView
    mbQuoteSearch
    mbQuoteRand
    mbQuoteStats
    mbQuoteByNick
    _printQuoteSyntax
);

sub mbQuotes_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;       # IRC nick of caller
    my $channel = $ctx->channel;    # may be undef in private
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # ---------------------------------------------------------
    # Syntax: if no subcommand given, show help and return
    # ---------------------------------------------------------
    unless (@args && defined $args[0] && $args[0] ne "") {
        $self->_printQuoteSyntax($nick);
        return;
    }

    # Subcommand (normalized)
    my $subcmd = lc shift @args;

    # ---------------------------------------------------------
    # Resolve user object (prefer Context, fallback to legacy)
    # ---------------------------------------------------------
    my $user = $ctx->user;

    my ($uid, $handle, $level, $level_desc) = (undef, undef, undef, undef);
    if ($user) {
        $uid        = eval { $user->id };
        $handle     = eval { $user->nickname } // $nick;
        $level      = eval { $user->level };
        $level_desc = eval { $user->level_description };
    }

    # ---------------------------------------------------------
    # Authenticated users with level >= "User"
    #   -> full access to all subcommands
    # ---------------------------------------------------------
    if ( $user && $user->is_authenticated && eval { $user->has_level('User') } ) {

        return mbQuoteAdd($self, $message, $uid, $handle, $nick, $channel, @args)
            if $subcmd =~ /^(add|a)$/;

        return mbQuoteDel($self, $message, $handle, $nick, $channel, @args)
            if $subcmd =~ /^(del|d)$/;

        return mbQuoteView($self, $message, $nick, $channel, @args)
            if $subcmd =~ /^(view|v)$/;

        return mbQuoteSearch($self, $message, $nick, $channel, @args)
            if $subcmd =~ /^(search|s)$/;

        return mbQuoteRand($self, $message, $nick, $channel, @args)
            if $subcmd =~ /^(random|r)$/;

        return mbQuoteStats($self, $message, $nick, $channel, @args)
            if $subcmd eq "stats";

        # Unknown subcommand for authenticated user
        $self->_printQuoteSyntax($nick);
        return;
    }

    # ---------------------------------------------------------
    # Unauthenticated or low-level users
    #   -> only view/search/random/stats
    #   -> BUT "add" is still allowed (legacy behavior),
    #      using undef uid/handle, with sNick + channel
    # ---------------------------------------------------------

    # Read-only subcommands
    return mbQuoteView($self, $message, $nick, $channel, @args)
        if $subcmd =~ /^(view|v)$/;

    return mbQuoteSearch($self, $message, $nick, $channel, @args)
        if $subcmd =~ /^(search|s)$/;

    return mbQuoteRand($self, $message, $nick, $channel, @args)
        if $subcmd =~ /^(random|r)$/;

    return mbQuoteStats($self, $message, $nick, $channel, @args)
        if $subcmd eq "stats";

    # Anonymous/legacy add (no user id/handle)
    return mbQuoteAdd($self, $message, undef, undef, $nick, $channel, @args)
        if $subcmd =~ /^(add|a)$/;

    # ---------------------------------------------------------
    # At this point, the user is either unauthenticated or
    # does not have the required level for the requested
    # subcommand (e.g. "del" without proper rights).
    # ---------------------------------------------------------
    my $who   = defined $handle ? $handle : $nick;
    my $pfx   = ($message && $message->can('prefix')) ? $message->prefix : $nick;
    my $descr = $level_desc // $level // 'unknown';

    my $logmsg = "$pfx q command attempt (user $who is not logged in or insufficient level [$descr])";
    noticeConsoleChan($self, $logmsg);

    botNotice(
        $self,
        $nick,
        "You must be logged to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
    );

    return;
}

# Display the syntax for the quote command
sub _printQuoteSyntax {
	my ($self, $sNick) = @_;
	botNotice($self, $sNick, "Quotes syntax:");
	botNotice($self, $sNick, "q [add or a] text1 | text2 | ... | textn");
	botNotice($self, $sNick, "q [del or d] id");
	botNotice($self, $sNick, "q [view or v] id");
	botNotice($self, $sNick, "q [search or s] text");
	botNotice($self, $sNick, "q [random or r]");
	botNotice($self, $sNick, "q stats");
}

# Add a new quote to the database for the specified channel
# Add a new quote to the database for the specified channel
sub mbQuoteAdd {
    my ($self, $message, $iMatchingUserId, $sMatchingUserHandle, $sNick, $sChannel, @tArgs) = @_;

    unless (defined($tArgs[0]) && $tArgs[0] ne "") {
        botNotice($self, $sNick, "q [add or a] text1 | text2 | ... | textn");
        return;
    }

    my $sQuoteText = join(" ", @tArgs);

    # B2/A2: limit quote text length
    if (length($sQuoteText) > 512) {
        botNotice($self, $sNick, "Quote text too long (max 512 chars).");
        return;
    }

    my $sQuery = "SELECT QUOTES.id_quotes FROM QUOTES JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel WHERE CHANNEL.name = ? AND QUOTES.quotetext = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "mbQuoteAdd() SQL prepare error: $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while checking quote.");
        return;
    }

    unless ($sth->execute($sChannel, $sQuoteText)) {
        $self->{logger}->log(1, "mbQuoteAdd() SQL execute error: $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $sNick, "Database error while checking quote.");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_quotes = $ref->{'id_quotes'};
        $sth->finish;

        botPrivmsg($self, $sChannel, "Quote (id: $id_quotes) already exists");
        logBot($self, $message, $sChannel, "q", @tArgs);
        return;
    }

    $sth->finish;

    my $channel_obj = $self->{channels}{$sChannel} || $self->{channels}{lc($sChannel)};

    unless (defined($channel_obj)) {
        botNotice($self, $sNick, "Channel $sChannel is not registered to me");
        return;
    }

    my $id_channel = $channel_obj->get_id;

    $sQuery = "INSERT INTO QUOTES (id_channel, id_user, quotetext) VALUES (?, ?, ?)";
    $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "mbQuoteAdd() SQL insert prepare error: $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while adding quote.");
        return;
    }

    my $id_user = ($iMatchingUserId && $iMatchingUserId =~ /^\d+$/) ? $iMatchingUserId : 0;

    unless ($sth->execute($id_channel, $id_user, $sQuoteText)) {
        $self->{logger}->log(1, "mbQuoteAdd() SQL insert execute error: $DBI::errstr | Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $sNick, "Database error while adding quote.");
        return;
    }

    $sth->finish;

    my $id_inserted = $self->{dbh}->last_insert_id(undef, undef, undef, undef);
    $id_inserted //= $self->{dbh}->{mysql_insertid};
    $id_inserted //= '?';

    my $id_bold = String::IRC->new($id_inserted)->bold;
    my $prefix = defined($sMatchingUserHandle) ? "($sMatchingUserHandle) " : "";

    botPrivmsg($self, $sChannel, "$prefix" . "done. (id: $id_bold)");
    logBot($self, $message, $sChannel, "q add", @tArgs);
    return $id_inserted;
}



sub mbQuoteDel {
    my ($self, $message, $sMatchingUserHandle, $sNick, $sChannel, @tArgs) = @_;

    my $id_quotes = $tArgs[0];

    unless (defined($id_quotes) && $id_quotes =~ /^\d+$/) {
        botNotice($self, $sNick, "q [del or q] id");
        return;
    }

    my $sQuery = "SELECT QUOTES.id_quotes FROM QUOTES JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel WHERE CHANNEL.name = ? AND QUOTES.id_quotes = ?";
    my $sth_sel = $self->{dbh}->prepare($sQuery);

    unless ($sth_sel) {
        $self->{logger}->log(1, "mbQuoteDel() SQL prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while checking quote.");
        return;
    }

    unless ($sth_sel->execute($sChannel, $id_quotes)) {
        $self->{logger}->log(1, "mbQuoteDel() SQL execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth_sel->finish;
        botNotice($self, $sNick, "Database error while checking quote.");
        return;
    }

    my $exists = $sth_sel->fetchrow_hashref();
    $sth_sel->finish;

    unless ($exists) {
        botPrivmsg($self, $sChannel, "Quote (id : $id_quotes) does not exist for channel $sChannel");
        return;
    }

    $sQuery = "DELETE FROM QUOTES WHERE id_quotes=?";
    my $sth_del = $self->{dbh}->prepare($sQuery);

    unless ($sth_del) {
        $self->{logger}->log(1, "mbQuoteDel() SQL delete prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while deleting quote.");
        return;
    }

    unless ($sth_del->execute($id_quotes)) {
        $self->{logger}->log(1, "mbQuoteDel() SQL delete execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth_del->finish;
        botNotice($self, $sNick, "Database error while deleting quote.");
        return;
    }

    $sth_del->finish;

    my $id_removed = String::IRC->new($id_quotes)->bold;
    botPrivmsg($self, $sChannel, "($sMatchingUserHandle) deleted. (id: $id_removed)");
    logBot($self, $message, $sChannel, "q del", @tArgs);

    return 1;
}


sub mbQuoteView {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $id_quotes = $tArgs[0];

    unless (defined($id_quotes) && $id_quotes =~ /^\d+$/) {
        botNotice($self, $sNick, "q [view or v] id");
        return;
    }

    my $sQuery =
        "SELECT QUOTES.id_quotes, QUOTES.quotetext, QUOTES.id_user, USER.nickname AS user_nickname ".
        "FROM QUOTES ".
        "JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel ".
        "LEFT JOIN USER ON USER.id_user = QUOTES.id_user ".
        "WHERE CHANNEL.name = ? AND QUOTES.id_quotes = ?";

    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "mbQuoteView() SQL prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while reading quote.");
        return;
    }

    unless ($sth->execute($sChannel, $id_quotes)) {
        $self->{logger}->log(1, "mbQuoteView() SQL execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $sNick, "Database error while reading quote.");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_quotes  = $ref->{'id_quotes'};
        my $sQuoteText = $ref->{'quotetext'};
        my $id_user    = $ref->{'id_user'};

        my $sUserhandle = $ref->{'user_nickname'};

        if (!defined($sUserhandle) || $sUserhandle eq "") {
            $sUserhandle = getUserhandle($self, $id_user);
        }

        $sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");

        my $id_q = String::IRC->new($id_quotes)->bold;
        botPrivmsg($self, $sChannel, "($sUserhandle) [id: $id_q] $sQuoteText");
        logBot($self, $message, $sChannel, "q view", @tArgs);
    }
    else {
        botPrivmsg($self, $sChannel, "Quote (id : $id_quotes) does not exist for channel $sChannel");
    }

    $sth->finish;
    return 1;
}

                
sub mbQuoteSearch {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    unless (defined($tArgs[0]) && $tArgs[0] ne '') {
        botNotice($self, $sNick, "q [search or s] <text> [word2 ...]");
        return;
    }

    my $MAXQUOTES = 50;

    my @words = grep { defined($_) && $_ ne '' } @tArgs;

    unless (@words) {
        botNotice($self, $sNick, "q [search or s] <text> [word2 ...]");
        return;
    }

    my @like_words = map {
        my $w = $_;
        $w =~ s/!/!!/g;
        $w =~ s/%/!%/g;
        $w =~ s/_/!_/g;
        $w;
    } @words;

    my $where_words = join(' AND ', map { q{q.quotetext LIKE ? ESCAPE '!'} } @like_words);
    my @binds_words = map { "%$_%" } @like_words;

    my $sQuery = "SELECT q.id_quotes, q.quotetext, q.id_user, q.ts
                  FROM QUOTES q
                  JOIN CHANNEL c ON c.id_channel = q.id_channel
                  WHERE c.name = ?
                    AND $where_words
                  ORDER BY q.id_quotes DESC
                  LIMIT ?";

    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "mbQuoteSearch SQL prepare error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        botNotice($self, $sNick, "Database error during search.");
        return;
    }

    unless ($sth->execute($sChannel, @binds_words, $MAXQUOTES + 1)) {
        $self->{logger}->log(1, "mbQuoteSearch SQL execute error: $DBI::errstr Query: $sQuery")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $sNick, "Database error during search.");
        return;
    }

    my @rows;
    while (my $ref = $sth->fetchrow_hashref) {
        push @rows, $ref;
    }

    $sth->finish;

    my $display_text = join(' ', @words);

    if (!@rows) {
        botPrivmsg($self, $sChannel, "No quote found matching \"$display_text\" on $sChannel");
    }
    elsif (@rows > $MAXQUOTES) {
        botPrivmsg($self, $sChannel,
            "More than $MAXQUOTES quotes matching \"$display_text\" on $sChannel — please be more specific :)");
    }
    else {
        my $count = scalar @rows;
        my $id_list = join('|', map { $_->{id_quotes} } @rows);
        botPrivmsg($self, $sChannel,
            "$count quote(s) matching \"$display_text\" on $sChannel : $id_list");

        my $last   = $rows[0];
        my $id_q   = String::IRC->new($last->{id_quotes})->bold;
        my $handle = getUserhandle($self, $last->{id_user}) || 'Unknown';

        botPrivmsg($self, $sChannel,
            "Last on $last->{ts} by $handle (id : $id_q) $last->{quotetext}");
    }

    logBot($self, $message, $sChannel, "q search", @tArgs);
    return scalar(@rows);
}


sub mbQuoteRand {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $sql_count = "SELECT COUNT(*) FROM QUOTES q
         JOIN CHANNEL c ON c.id_channel = q.id_channel
         WHERE c.name = ?";

    my $sth_count = $self->{dbh}->prepare($sql_count);

    unless ($sth_count) {
        $self->{logger}->log(1, "mbQuoteRand count SQL prepare error: $DBI::errstr Query: $sql_count")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while reading quotes.");
        return;
    }

    unless ($sth_count->execute($sChannel)) {
        $self->{logger}->log(1, "mbQuoteRand count SQL execute error: $DBI::errstr Query: $sql_count")
            if $self->{logger};
        $sth_count->finish;
        botNotice($self, $sNick, "Database error while reading quotes.");
        return;
    }

    my ($count) = $sth_count->fetchrow_array;
    $sth_count->finish;

    unless ($count && $count > 0) {
        botPrivmsg($self, $sChannel, "Quote database is empty for $sChannel");
        logBot($self, $message, $sChannel, "q random", @tArgs);
        return;
    }

    my $offset = int(rand($count));

    my $sql = "SELECT q.id_quotes, q.quotetext, q.id_user
         FROM QUOTES q
         JOIN CHANNEL c ON c.id_channel = q.id_channel
         WHERE c.name = ?
         LIMIT 1 OFFSET ?";

    my $sth = $self->{dbh}->prepare($sql);

    unless ($sth) {
        $self->{logger}->log(1, "mbQuoteRand SQL prepare error: $DBI::errstr Query: $sql")
            if $self->{logger};
        botNotice($self, $sNick, "Database error while reading quote.");
        return;
    }

    unless ($sth->execute($sChannel, $offset)) {
        $self->{logger}->log(1, "mbQuoteRand SQL execute error: $DBI::errstr Query: $sql")
            if $self->{logger};
        $sth->finish;
        botNotice($self, $sNick, "Database error while reading quote.");
        return;
    }

    if (my $ref = $sth->fetchrow_hashref) {
        my $id_q   = String::IRC->new($ref->{id_quotes})->bold;
        my $handle = getUserhandle($self, $ref->{id_user}) || 'Unknown';

        botPrivmsg($self, $sChannel, "($handle) [id: $id_q] $ref->{quotetext}");
    }
    else {
        botPrivmsg($self, $sChannel, "Quote database is empty for $sChannel");
    }

    $sth->finish;
    logBot($self, $message, $sChannel, "q random", @tArgs);
    return 1;
}


sub mbQuoteStats {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $sQuery = "SELECT COUNT(*) AS nbQuotes,
                UNIX_TIMESTAMP(MIN(ts)) AS minDate,
                UNIX_TIMESTAMP(MAX(ts)) AS maxDate
                FROM QUOTES
                JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel
                WHERE CHANNEL.name = ?";

    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "mbQuoteStats() SQL prepare error: " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        botNotice($self, $sNick, "Database error while reading quote stats.");
        return;
    }

    unless ($sth->execute($sChannel)) {
        $self->{logger}->log(1, "mbQuoteStats() SQL execute error: " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        botNotice($self, $sNick, "Database error while reading quote stats.");
        return;
    }

    my $ref = $sth->fetchrow_hashref();
    $sth->finish;

    unless ($ref) {
        $self->{logger}->log(1, "mbQuoteStats() fetchrow failed")
            if $self->{logger};
        return;
    }

    my $nbQuotes = $ref->{'nbQuotes'} // 0;
    if ($nbQuotes == 0) {
        botPrivmsg($self, $sChannel, "Quote database is empty for $sChannel");
        return;
    }

    my $minDate = $ref->{'minDate'};
    my $maxDate = $ref->{'maxDate'};

    my @int = (
        [ 'second', 1                ],
        [ 'minute', 60               ],
        [ 'hour',   60*60            ],
        [ 'day',    60*60*24         ],
        [ 'month',  60*60*24*30      ],
        [ 'year',   60*60*24*365     ],
    );

    my $now = time();
    my $oldest = defined($minDate) ? $now - $minDate : 0;
    my $newest = defined($maxDate) ? $now - $maxDate : 0;

    my $fmt_age = sub {
        my ($age) = @_;
        my $best = "0 second";

        for my $i (reverse @int) {
            my ($label, $secs) = @$i;
            if ($age >= $secs) {
                my $n = int($age / $secs);
                $best = "$n $label" . ($n > 1 ? "s" : "");
                last;
            }
        }

        return $best;
    };

    my $oldest_txt = $fmt_age->($oldest);
    my $newest_txt = $fmt_age->($newest);

    botPrivmsg(
        $self,
        $sChannel,
        "Quote stats for $sChannel: $nbQuotes quote(s), oldest $oldest_txt ago, newest $newest_txt ago"
    );

    logBot($self, $message, $sChannel, "q stats", @tArgs);
    return $nbQuotes;
}


# Modify a user's global level, autologin status, or fortniteid (Context version)


# ---------------------------------------------------------------------------
# mbQuoteByNick — !quote <nick>
# Return a random quote added by a specific nick.
# ---------------------------------------------------------------------------
sub mbQuoteByNick {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $sNick   = $ctx->nick;
    my $sChannel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $targetNick = $args[0];

    unless (defined $targetNick && $targetNick ne '') {
        Mediabot::Helpers::botNotice($self, $sNick, "Syntax: quote <nick>");
        return;
    }

    my $like = lc($targetNick) . '%';

    # Count matching quotes
    my $sth_count = $self->{dbh}->prepare(q{
        SELECT COUNT(*) AS cnt
        FROM QUOTES q
        JOIN CHANNEL c ON c.id_channel = q.id_channel
        JOIN USER    u ON u.id_user    = q.id_user
        WHERE c.name = ? AND LOWER(u.nickname) LIKE ?
    });
    unless ($sth_count && $sth_count->execute($sChannel, $like)) {
        $self->{logger}->log(1, "mbQuoteByNick() count SQL error: $DBI::errstr");
        return undef;
    }
    my $cnt_row = $sth_count->fetchrow_hashref;
    $sth_count->finish;
    my $count = $cnt_row->{cnt} // 0;

    unless ($count > 0) {
        botNotice($self, $sNick, "No quotes from $targetNick on $sChannel.");
        return undef;
    }

    my $offset = int(rand($count));

    my $sth = $self->{dbh}->prepare(q{
        SELECT q.id_quotes, q.quotetext, u.nickname AS author
        FROM QUOTES q
        JOIN CHANNEL c ON c.id_channel = q.id_channel
        JOIN USER    u ON u.id_user    = q.id_user
        WHERE c.name = ? AND LOWER(u.nickname) LIKE ?
        ORDER BY q.id_quotes
        LIMIT 1 OFFSET ?
    });
    unless ($sth && $sth->execute($sChannel, $like, $offset)) {
        $self->{logger}->log(1, "mbQuoteByNick() SQL error: $DBI::errstr");
        return undef;
    }
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    return undef unless $row;

    botPrivmsg($self, $sChannel,
        sprintf("[%d] <%s> %s", $row->{id_quotes}, $row->{author}, $row->{quotetext}));
    return 1;
}


1;
