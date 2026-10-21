package Mediabot::IRC::Target;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(is_channel _is_irc_channel_target);

# Classification only, not syntax validation or an authorization decision.
sub _is_irc_channel_target {
    my ($target) = @_;
    return defined($target) && $target =~ /^[#&!+]/ ? 1 : 0;
}

sub is_channel { return _is_irc_channel_target(@_); }

1;
