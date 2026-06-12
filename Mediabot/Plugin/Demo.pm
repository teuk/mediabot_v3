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
        $bot->events->on(
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

sub observed_public {
    my ($self) = @_;
    return $self->{observed_public} || 0;
}

1;
