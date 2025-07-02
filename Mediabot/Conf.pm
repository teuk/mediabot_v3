package Mediabot::Conf;

use strict;
use warnings;
use Config::Simple;

sub new {
    my ($class, $conf_ref, $file) = @_;
    my $self = {
        _conf => $conf_ref || {},
        _file => $file,
        _cfg  => undef,
    };

    if ($file) {
        my $cfg = Config::Simple->new(filename => $file);
        $self->{_cfg}  = $cfg;
        $self->{_conf} = { $cfg->vars() }; # sync initial values
    }

    bless $self, $class;
    return $self;
}

sub get {
    my ($self, $key) = @_;
    return $self->{_conf}{$key};
}

sub set {
    my ($self, $key, $value) = @_;
    $self->{_conf}{$key} = $value;
    $self->{_cfg}->param($key => $value) if $self->{_cfg};
}

sub save {
    my ($self) = @_;
    return unless $self->{_cfg} and $self->{_file};
    $self->{_cfg}->write($self->{_file});
}

sub all {
    my ($self) = @_;
    return %{ $self->{_conf} };
}

1;

__END__

=pod

=head1 NAME

Mediabot::Conf - Magic configuration wrapper for Mediabot with read/write support

=head1 SYNOPSIS

    use Mediabot::Conf;

    # Load config from file
    my $conf = Mediabot::Conf->new(undef, '/path/to/config.conf');

    # Get a value
    my $bot_name = $conf->get('main.bot_name');

    # Set a value
    $conf->set('main.bot_name', 'NewBot');

    # Save changes back to the config file
    $conf->save();

=head1 DESCRIPTION

C<Mediabot::Conf> provides a simple and unified interface for reading,
modifying, and saving configuration values for Mediabot.

It wraps L<Config::Simple> behind a clean object interface and keeps an
internal hash mirror for convenience.

=head1 METHODS

=head2 new($hashref, $file_path)

Creates a new configuration object. If a config file path is provided, it will
be read using L<Config::Simple>. All keys/values will be stored internally and
can later be written back.

=head2 get($key)

Returns the value associated with C<$key>, or undef if not found.

=head2 set($key, $value)

Sets or updates a configuration value in memory. If the object was created with
a config file, the change is mirrored in the underlying C<Config::Simple>
object.

=head2 save

Writes all pending changes back to the original configuration file. Has no effect
if the object was not constructed with a file path.

=head2 all

Returns the full configuration as a hash (not a hashref).

=head1 AUTHOR

Christophe "teuk" <teuk@teuk.org>

=head1 LICENSE

This module is part of the Mediabot project and distributed under the same license.

=cut
