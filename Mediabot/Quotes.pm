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
sub mbQuoteAdd {
	my ($self, $message, $iMatchingUserId, $sMatchingUserHandle, $sNick, $sChannel, @tArgs) = @_;

	# Require at least one argument
	unless (defined($tArgs[0]) && $tArgs[0] ne "") {
		botNotice($self, $sNick, "q [add or a] text1 | text2 | ... | textn");
		return;
	}

	my $sQuoteText = join(" ", @tArgs);

	# Check for existing quote on this channel
	my $sQuery = "SELECT * FROM QUOTES, CHANNEL WHERE CHANNEL.id_channel = QUOTES.id_channel AND name = ? AND quotetext LIKE ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel, $sQuoteText)) {
		$self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sQuery");
		return;
	}

	if (my $ref = $sth->fetchrow_hashref()) {
		my $id_quotes = $ref->{'id_quotes'};
		botPrivmsg($self, $sChannel, "Quote (id: $id_quotes) already exists");
		logBot($self, $message, $sChannel, "q", @tArgs);
		$sth->finish;
		return;
	}
	$sth->finish;

	# Get channel object
	my $channel_obj = $self->{channels}{$sChannel};

	unless (defined($channel_obj)) {
		botNotice($self, $sNick, "Channel $sChannel is not registered to me");
		return;
	}

	my $id_channel = $channel_obj->get_id;

	# Insert quote
	$sQuery = "INSERT INTO QUOTES (id_channel, id_user, quotetext) VALUES (?, ?, ?)";
	$sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($id_channel, ($iMatchingUserId && $iMatchingUserId =~ /^\d+$/ ? $iMatchingUserId : 0), $sQuoteText)) {
		$self->{logger}->log(1, "SQL Error: $DBI::errstr | Query: $sQuery");
	} else {
		my $id_inserted = String::IRC->new($sth->{mysql_insertid})->bold;
		my $prefix = defined($sMatchingUserHandle) ? "($sMatchingUserHandle) " : "";
		botPrivmsg($self, $sChannel, "$prefix" . "done. (id: $id_inserted)");
		logBot($self, $message, $sChannel, "q add", @tArgs);
	}
	$sth->finish;
}


sub mbQuoteDel(@) {
	my ($self,$message,$sMatchingUserHandle,$sNick,$sChannel,@tArgs) = @_;
	my $id_quotes = $tArgs[0];
	unless (defined($tArgs[0]) && ($tArgs[0] ne "") && ($id_quotes =~ /[0-9]+/)) {
		botNotice($self,$sNick,"q [del or q] id");
	}
	else {
		my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? AND id_quotes=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$id_quotes)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				$sQuery = "DELETE FROM QUOTES WHERE id_quotes=?";
				my $sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($id_quotes)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					my $id_removed = String::IRC->new($id_quotes)->bold;
					botPrivmsg($self,$sChannel,"($sMatchingUserHandle) done. (id: $id_removed)");
					logBot($self,$message,$sChannel,"q del",@tArgs);
				}
			}
			else {
				botPrivmsg($self,$sChannel,"Quote (id : $id_quotes) does not exist for channel $sChannel");
			}
		}
		$sth->finish;
	}
}

sub mbQuoteView(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $id_quotes = $tArgs[0];
	unless (defined($tArgs[0]) && ($tArgs[0] ne "") && ($id_quotes =~ /[0-9]+/)) {
		botNotice($self,$sNick,"q [view or v] id");
	}
	else {
		my $sQuery =
			"SELECT QUOTES.*,CHANNEL.*,USER.nickname AS user_nickname ".
			"FROM QUOTES ".
			"JOIN CHANNEL ON CHANNEL.id_channel = QUOTES.id_channel ".
			"LEFT JOIN USER ON USER.id_user = QUOTES.id_user ".
			"WHERE CHANNEL.name LIKE ? AND QUOTES.id_quotes = ?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel,$id_quotes)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			if (my $ref = $sth->fetchrow_hashref()) {
				my $id_quotes  = $ref->{'id_quotes'};
				my $sQuoteText = $ref->{'quotetext'};
				my $id_user    = $ref->{'id_user'};

				# 1) handle depuis la jointure USER
				my $sUserhandle = $ref->{'user_nickname'};

				# 2) sinon on tente l'ancien getUserhandle()
				if (!defined($sUserhandle) || $sUserhandle eq "") {
					$sUserhandle = getUserhandle($self,$id_user);
				}

				# 3) fallback final
				$sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");

				my $id_q = String::IRC->new($id_quotes)->bold;
				botPrivmsg($self,$sChannel,"($sUserhandle) [id: $id_q] $sQuoteText");
				logBot($self,$message,$sChannel,"q view",@tArgs);
			}
			else {
				botPrivmsg($self,$sChannel,"Quote (id : $id_quotes) does not exist for channel $sChannel");
			}
		}
		$sth->finish;
	}
}
                
sub mbQuoteSearch(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	unless (defined($tArgs[0]) && ($tArgs[0] ne "")) {
		botNotice($self,$sNick,"q [search or s] text");
	}
	else {
		my $MAXQUOTES = 50;
		my $sQuoteText = join(" ",@tArgs);
		my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name=?";
		my $sth = $self->{dbh}->prepare($sQuery);
		unless ($sth->execute($sChannel)) {
			$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
		}
		else {
			my $i = 0;
			my $sQuotesIdFound;
			my $sLastQuote;
			my $ref;
			my $id_quotes;
			my $id_user;
			my $ts;
			while ($ref = $sth->fetchrow_hashref()) {
				my $sQuote = $ref->{'quotetext'};
				if ( $sQuote =~ /$sQuoteText/i ) {
					$id_quotes = $ref->{'id_quotes'};
					$id_user = $ref->{'id_user'};
					$ts = $ref->{'ts'};
					if ( $i == 0) {
						$sQuotesIdFound .= "$id_quotes";
					}
					else {
						$sQuotesIdFound .= "|$id_quotes";
					}
					$sLastQuote = $sQuote;
					$i++;
				}
			}
			if ( $i == 0) {
				botPrivmsg($self,$sChannel,"No quote found matching \"$sQuoteText\" on $sChannel");
			}
			elsif ( $i <= $MAXQUOTES ) {
					botPrivmsg($self,$sChannel,"$i quote(s) matching \"$sQuoteText\" on $sChannel : $sQuotesIdFound");
					my $id_q = String::IRC->new($id_quotes)->bold;
					my $sUserHandle = getUserhandle($self,$id_user);
					$sUserHandle = ((defined($sUserHandle) && ($sUserHandle ne "")) ? $sUserHandle : "Unknown");
					botPrivmsg($self,$sChannel,"Last on $ts by $sUserHandle (id : $id_q) $sLastQuote");
			}
			else {
					botPrivmsg($self,$sChannel,"More than $MAXQUOTES quotes matching \"$sQuoteText\" found on $sChannel, please be more specific :)");
			}
			logBot($self,$message,$sChannel,"q search",@tArgs);
		}
		$sth->finish;
	}
}

sub mbQuoteRand(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT * FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER BY RAND() LIMIT 1";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $id_quotes = $ref->{'id_quotes'};
			my $sQuoteText = $ref->{'quotetext'};
			my $id_user = $ref->{'id_user'};
			my $sUserhandle = getUserhandle($self,$id_user);
			$sUserhandle = (defined($sUserhandle) && ($sUserhandle ne "") ? $sUserhandle : "Unknown");
			my $id_q = String::IRC->new($id_quotes)->bold;
			botPrivmsg($self,$sChannel,"($sUserhandle) [id: $id_q] $sQuoteText");
		}
		else {
			botPrivmsg($self,$sChannel,"Quote database is empty for $sChannel");
		}
		logBot($self,$message,$sChannel,"q random",@tArgs);
	}
	$sth->finish;
}

sub mbQuoteStats(@) {
	my ($self,$message,$sNick,$sChannel,@tArgs) = @_;
	my $sQuery = "SELECT count(*) as nbQuotes FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ?";
	my $sth = $self->{dbh}->prepare($sQuery);
	unless ($sth->execute($sChannel)) {
		$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
	}
	else {
		if (my $ref = $sth->fetchrow_hashref()) {
			my $nbQuotes = $ref->{'nbQuotes'};
			if ( $nbQuotes == 0) {
				botPrivmsg($self,$sChannel,"Quote database is empty for $sChannel");
			}
			else {
				$sQuery = "SELECT UNIX_TIMESTAMP(ts) as minDate FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER by ts LIMIT 1";
				$sth = $self->{dbh}->prepare($sQuery);
				unless ($sth->execute($sChannel)) {
					$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
				}
				else {
					if (my $ref = $sth->fetchrow_hashref()) {
						my $minDate = $ref->{'minDate'};
						$sQuery = "SELECT UNIX_TIMESTAMP(ts) as maxDate FROM QUOTES,CHANNEL WHERE CHANNEL.id_channel=QUOTES.id_channel AND name like ? ORDER by ts DESC LIMIT 1";
						$sth = $self->{dbh}->prepare($sQuery);
						unless ($sth->execute($sChannel)) {
							$self->{logger}->log(1,"SQL Error : " . $DBI::errstr . " Query : " . $sQuery);
						}
						else {
							if (my $ref = $sth->fetchrow_hashref()) {
								my $maxDate = $ref->{'maxDate'};
								my $d = time() - $minDate;
								my @int = (
								    [ 'second', 1                ],
								    [ 'minute', 60               ],
								    [ 'hour',   60*60            ],
								    [ 'day',    60*60*24         ],
								    [ 'week',   60*60*24*7       ],
								    [ 'month',  60*60*24*30.5    ],
								    [ 'year',   60*60*24*30.5*12 ]
								);
								my $i = $#int;
								my @r;
								while ( ($i>=0) && ($d) )
								{
								    if ($d / $int[$i] -> [1] >= 1)
								    {
								        push @r, sprintf "%d %s%s",
								                     $d / $int[$i] -> [1],
								                     $int[$i]->[0],
								                     ( sprintf "%d", $d / $int[$i] -> [1] ) > 1
								                         ? 's'
								                         : '';
								    }
								    $d %= $int[$i] -> [1];
								    $i--;
								}
								my $minTimeAgo = join ", ", @r if @r;
								@r = ();
								$d = time() - $maxDate;
								$i = $#int;
								while ( ($i>=0) && ($d) )
								{
								    if ($d / $int[$i] -> [1] >= 1)
								    {
								        push @r, sprintf "%d %s%s",
								                     $d / $int[$i] -> [1],
								                     $int[$i]->[0],
								                     ( sprintf "%d", $d / $int[$i] -> [1] ) > 1
								                         ? 's'
								                         : '';
								    }
								    $d %= $int[$i] -> [1];
								    $i--;
								}
								my $maxTimeAgo = join ", ", @r if @r;
								botPrivmsg($self,$sChannel,"Quotes : $nbQuotes for channel $sChannel -- first : $minTimeAgo ago -- last : $maxTimeAgo ago");
								logBot($self,$message,$sChannel,"q stats",@tArgs);
							}
						}
					}
				}
			}
		}
	}
	$sth->finish;
}

# Modify a user's global level, autologin status, or fortniteid (Context version)

1;
