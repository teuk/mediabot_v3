package Mediabot::Command;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        name    => $args{name},        # 'stat', 'help', etc.
        args    => $args{args} || [],  # [ 'foo', 'bar' ]
        raw     => $args{raw},         # ligne brute complète
        context => $args{context},     # Mediabot::Context
        source  => $args{source} || 'public',   # 'public' | 'private' | 'system'...
    }, $class;

    return $self;
}

# --- Getters ---

sub name    { $_[0]->{name}    }
sub args    { $_[0]->{args}    }
sub raw     { $_[0]->{raw}     }
sub context { $_[0]->{context} }
sub source  { $_[0]->{source}  }

# Context shortcuts

sub nick       { $_[0]->context->nick       }
sub channel    { $_[0]->context->channel    }
sub is_private { $_[0]->context->is_private }
sub user       { $_[0]->context->user       }
sub channel_obj{ $_[0]->context->channel_obj }

# --- Arguments helpers ---

sub arg {
    my ($self, $index, $default) = @_;
    $index //= 0;

    return defined $self->{args}->[$index]
        ? $self->{args}->[$index]
        : $default;
}

sub args_as_string {
    my ($self, $start_index) = @_;
    $start_index //= 0;

    return join ' ', @{ $self->{args} }[$start_index .. $#{$self->{args}}]
        if @{$self->{args}} > $start_index;

    return '';
}

# --- Helpers pour répondre ---

sub reply {
    my ($self, $msg) = @_;
    return $self->context->reply($msg);
}

sub reply_private {
    my ($self, $msg) = @_;
    return $self->context->reply_private($msg);
}

sub reply_channel {
    my ($self, $msg) = @_;
    return $self->context->reply_channel($msg);
}

# --- Rights helpers (will rely on Mediabot::User / Auth) ---

sub require_auth_level {
    my ($self, $level) = @_;
    my $user = $self->user;

    # To be adjusted according to your auth system
    if (!$user) {
        $self->reply_private("Tu dois être authentifié pour utiliser cette commande.");
        return;
    }

    if (!$user->has_level($level)) {
        $self->reply_private("Tu n'as pas les droits pour cette commande.");
        return;
    }

    return 1;
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

sub log_info {
    my ($self, $msg) = @_;
    my $ctx = $self->context or return;
    $ctx->log_info($msg);
}

sub log_error {
    my ($self, $msg) = @_;
    my $ctx = $self->context or return;
    $ctx->log_error($msg);
}

sub log_debug {
    my ($self, $msg) = @_;
    my $ctx = $self->context or return;
    $ctx->log_debug($msg);
}

1;

