package Mediabot::Spark::Identity;

use strict;
use warnings;

use Exporter 'import';
use Mediabot::IRC::CaseMapping qw(fold_irc);

our $VERSION = '1.0';
our @EXPORT_OK = qw(is_known_bot_nick);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value);
}

sub _nick_key {
    my ($nick, $mapping) = @_;
    return undef unless _plain_scalar($nick);
    $nick = "$nick";
    $nick =~ s/^\s+|\s+$//g;
    return undef unless length($nick) >= 1
        && length($nick) <= 100
        && $nick !~ /[\s,:\x00-\x1f\x7f]/;
    return fold_irc($nick, $mapping);
}

sub is_known_bot_nick {
    my (%args) = @_;

    my $wanted = _nick_key($args{nick}, $args{casemapping});
    return 0 unless defined $wanted;

    my %known;
    my $self = _nick_key($args{bot_nick}, $args{casemapping});
    $known{$self} = 1 if defined $self;

    if (_plain_scalar($args{configured_bot_nicks})) {
        for my $raw (split /,/, "$args{configured_bot_nicks}") {
            my $nick = _nick_key($raw, $args{casemapping});
            $known{$nick} = 1 if defined $nick;
        }
    }

    return $known{$wanted} ? 1 : 0;
}

1;
