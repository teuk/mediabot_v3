package Mediabot::IRC::Output;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(privmsg action notice);

# All public output goes through Helpers, including imported aliases in workers.
sub privmsg {
    require Mediabot::Helpers;
    return Mediabot::Helpers::botPrivmsg(@_);
}

sub action {
    require Mediabot::Helpers;
    return Mediabot::Helpers::botAction(@_);
}

sub notice {
    require Mediabot::Helpers;
    return Mediabot::Helpers::botNotice(@_);
}

1;
