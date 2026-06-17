package Mediabot::Plugin::Demo;

use strict;
use warnings;
use utf8;

our $VERSION = '0.001';

# ---------------------------------------------------------------------------
# Mediabot::Plugin::Demo
# ---------------------------------------------------------------------------
# mb171-B1: first trusted in-process Perl demo plugin.
#
# This plugin is deliberately tiny and safe. It registers one internal listener
# on EventBus, but it is not loaded unless the administrator explicitly enables
# it through PluginManager/load_configured_plugins().
# ---------------------------------------------------------------------------

sub register {
    my ($class, $bot, %opts) = @_;

    my $self = bless {
        bot             => $bot,
        manager         => $opts{manager},
        observed_public => 0,
    }, $class;

    if ($bot && $bot->can('events') && $bot->events) {
        # mb285-B1: keep the listener entry so unregister() can remove it on
        # plugin reload/replace. Without this the EventBus listener would leak as
        # a ghost on every reload, and the closure below (which captures $self,
        # which holds $bot) would keep a reference cycle alive.
        $self->{listener_entry} = $bot->events->on(
            public_command_observed => sub {
                my ($ctx) = @_;
                $self->{observed_public}++;

                # Keep this demo plugin observational only. It must not reply,
                # mutate command dispatch, touch DB, or alter Context.
                return;
            },
            name   => 'demo-public-command-observer',
            plugin => __PACKAGE__,
        );
    }

    return $self;
}

# mb285-B1: mirror Mediabot::Plugin::ScriptDryRun — a plugin that registers an
# EventBus listener MUST be able to remove it, so PluginManager's reload/replace
# (and explicit unregister) does not accumulate ghost listeners or leak the
# plugin object through the listener->$self->$bot reference cycle.
sub unregister {
    my ($self, %opts) = @_;

    my $bot   = $self->{bot};
    my $entry = $self->{listener_entry};
    return 0 unless $bot && $bot->can('events') && $bot->events && $entry;

    my $removed = eval { $bot->events->off(public_command_observed => $entry) } || 0;
    delete $self->{listener_entry} if $removed;
    return $removed ? 1 : 0;
}

sub observed_public {
    my ($self) = @_;
    return $self->{observed_public} || 0;
}

1;
