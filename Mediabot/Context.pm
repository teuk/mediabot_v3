package Mediabot::Context;

use strict;
use warnings;

=head1 NAME

Mediabot::Context - Lightweight container for command execution context.

=head1 DESCRIPTION

This object carries all contextual information for a single command
execution: bot instance, message object, IRC nick, channel, command
name and arguments. It also provides thin helpers for replying,
logging, and access control using the shared Mediabot infrastructure.

=head1 SYNOPSIS

    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => $sCommand,
        args    => \@tArgs,
    );

    $ctx->reply("Hello!");
    $ctx->reply_private("Only you can see this.");
    return $ctx->deny("Access denied.") unless $ctx->require_level('Master');

=cut

#----------------------------------------------------------------------
# Constructor
#----------------------------------------------------------------------

sub new {
    my ($class, %args) = @_;

    my $self = {
        bot     => $args{bot},
        message => $args{message},
        nick    => $args{nick},
        channel => $args{channel},
        command => $args{command},
        args    => $args{args} // [],
    };

    $self->{user} = undef;

    return bless $self, $class;
}

#----------------------------------------------------------------------
# Basic accessors
#----------------------------------------------------------------------

sub bot     { $_[0]->{bot} }
sub message { $_[0]->{message} }
sub nick    { $_[0]->{nick} }
sub channel { $_[0]->{channel} }
sub command { $_[0]->{command} }

# Always return an arrayref for args
sub args {
    my ($self) = @_;
    my $args = $self->{args};

    return []        unless defined $args;
    return $args     if ref $args eq 'ARRAY';
    return [ $args ];
}

# Return the Mediabot::Command object attached to this context (if any)
sub command_obj { $_[0]->{command_obj} }

# True if the command was issued in a private message (no channel)
sub is_private {
    my ($self) = @_;
    my $chan = $self->{channel} // '';
    return $chan !~ /^#/;
}

# Return the Channel object for the current channel, or undef
sub channel_obj {
    my ($self) = @_;
    my $bot  = $self->{bot}  or return undef;
    my $chan = $self->{channel} or return undef;
    return $bot->{channels}{$chan} // undef;
}

#----------------------------------------------------------------------
# User access
#----------------------------------------------------------------------

# Return caller user object (cached)
sub user {
    my ($self) = @_;
    return $self->{user} if $self->{user};

    my $bot     = $self->bot;
    my $message = $self->message;

    my $user = $bot->get_user_from_message($message);
    $self->{user} = $user if $user;
    return $user;
}

# Ensure user is authenticated (with optional autologin)
sub require_auth {
    my ($self) = @_;

    my $bot     = $self->bot;
    my $message = $self->message;
    my $nick    = $self->nick;

    my $user = $self->user;
    return unless $user;

    unless ($user->is_authenticated) {
        my $prefix = ($message && $message->can('prefix')) ? $message->prefix : '';
        my $did = eval { Mediabot::User::maybe_autologin($bot, $user, $nick, $prefix) } || 0;
        $user->{auth} = 1 if $did;
    }

    unless ($user->is_authenticated) {
        $bot->botNotice(
            $nick,
            "You must be logged to use this command - /msg "
              . $bot->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    return $user;
}

# Require a minimum privilege level
sub require_level {
    my ($self, $level) = @_;

    my $user = $self->user;

    return $self->deny("You must be logged in to use this command.")
        unless $user && $user->is_authenticated;

    return 1 if $user->has_level($level);

    return $self->deny("Your level does not allow you to use this command.");
}

# Send a notice to the caller and return undef (use as: return $ctx->deny(...))
sub deny {
    my ($self, $msg) = @_;

    my $bot = $self->{bot};
    return unless $bot;

    $bot->botNotice($self->{nick}, $msg);

    return;
}

#----------------------------------------------------------------------
# Reply helpers
#----------------------------------------------------------------------

# Send a PRIVMSG to the channel (public reply)
sub reply {
    my ($self, $msg) = @_;
    my $bot = $self->{bot} or return;
    $bot->botPrivmsg($self->{channel}, $msg);
}

# Send a PRIVMSG to the channel (explicit public reply — alias of reply)
sub reply_channel {
    my ($self, $msg) = @_;
    my $bot = $self->{bot} or return;
    $bot->botPrivmsg($self->{channel}, $msg);
}

# Send a NOTICE to the calling nick (private reply)
sub reply_private {
    my ($self, $msg) = @_;
    my $bot = $self->{bot} or return;
    $bot->botNotice($self->{nick}, $msg);
}

#----------------------------------------------------------------------
# Logging helpers
#----------------------------------------------------------------------

# Generic logging entry point.
# Delegates to $bot->{logger}->log($level, $msg) if available.
sub log {
    my ($self, $level, $msg) = @_;
    return unless defined $msg && $msg ne '';

    my $bot    = $self->{bot}     or return;
    my $logger = $bot->{logger}   or return;

    my $nick = defined $self->{nick}    ? $self->{nick}    : '?';
    my $chan = defined $self->{channel} ? $self->{channel} : '(priv)';
    my $cmd  = defined $self->{command} ? $self->{command} : '';

    my $ctx_prefix = "CTX nick=$nick chan=$chan";
    $ctx_prefix   .= " cmd=$cmd" if $cmd ne '';

    $logger->log($level, "$ctx_prefix :: $msg");
}

# Log at INFO level (0)
sub log_info {
    my ($self, $msg) = @_;
    $self->log(0, $msg);
}

# Log at ERROR level (1)
sub log_error {
    my ($self, $msg) = @_;
    $self->log(1, $msg);
}

# Log at DEBUG level (default 1, configurable)
# Example: $ctx->log_debug(3, "something happened");
sub log_debug {
    my ($self, $level, $msg) = @_;
    $level //= 1;
    $self->log($level, $msg);
}

1;
