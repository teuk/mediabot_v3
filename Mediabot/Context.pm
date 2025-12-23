package Mediabot::Context;

use strict;
use warnings;

=head1 NAME

Mediabot::Context - Lightweight container for command execution context.

=head1 DESCRIPTION

This object carries all contextual information for a single command
execution: bot instance, message object, IRC nick, channel, command
name and arguments. It also provides thin helpers for logging using
the shared Mediabot::Log instance.

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
        botNotice(
            $bot,
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

    # Your rule: only rely on User->has_level (no checkUserLevel anywhere)
    return 1 if $user->has_level($level);

    return $self->deny("Your level does not allow you to use this command.");
}

# Send a notice to the caller and return undef
sub deny {
    my ($self, $msg) = @_;

    my $bot = $self->{bot};
    return unless $bot;

    # Send notice to user
    $bot->botNotice($self->{nick}, $msg);

    return;
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

    # No args -> always an empty arrayref
    return [] unless defined $args;

    # Already an arrayref -> keep as is
    return $args if ref $args eq 'ARRAY';

    # Scalar or other -> wrap into an arrayref
    return [ $args ];
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

    # Build a lightweight context prefix (no leading [TAG] to keep
    # Mediabot::Log free to add its own [INFO]/[DEBUGx] labels).
    my $nick = defined $self->{nick}    ? $self->{nick}    : '?';
    my $chan = defined $self->{channel} ? $self->{channel} : '(priv)';
    my $cmd  = defined $self->{command} ? $self->{command} : '';

    my $ctx_prefix = "CTX nick=$nick chan=$chan";
    $ctx_prefix   .= " cmd=$cmd" if $cmd ne '';

    $logger->log($level, "$ctx_prefix :: $msg");
}

# Convenience wrapper for debug-style messages.
# Example: $ctx->log_debug(3, "something happened");
sub log_debug {
    my ($self, $level, $msg) = @_;
    $level //= 1;   # default to DEBUG1 if no level provided
    $self->log($level, $msg);
}

1;
