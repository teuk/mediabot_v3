package Mediabot::AI::IRCOutput;

use strict;
use warnings;
use utf8;

use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);
use Exporter 'import';


our $VERSION = '1.00';
our @EXPORT_OK = qw(
    format_ai_reply
    with_irc_output_instruction
);

use Mediabot::IRC::Presentation qw(
    _wire_bytes _decode_entity _markdown_to_irc _style_after _balanced_line _plain_suffix format_ai_reply IRC_BOLD IRC_RESET IRC_ITALIC IRC_UNDERLINE MAX_IRC_LINES MAX_IRC_BYTES
);

my $IRC_OUTPUT_INSTRUCTION =
    'Keep the visible answer concise enough for at most two compact IRC lines. '
  . 'Avoid Markdown headings, tables, block quotes, lists and fenced code. '
  . 'If emphasis helps, use only bold, italics or underline.';

sub with_irc_output_instruction {
    my ($system) = @_;

    $system = '' unless defined($system) && !ref($system);
    $system =~ s/[\r\n\0]+/ /g;
    $system =~ s/\s{2,}/ /g;
    $system =~ s/^\s+|\s+$//g;
    $system =~ s/\bAlways respond using a maximum of 10 lines of text and line-based[.]\s*//i;
    $system =~ s/\s{2,}/ /g;
    $system =~ s/^\s+|\s+$//g;

    return $system if index($system, $IRC_OUTPUT_INSTRUCTION) >= 0;

    return length($system)
        ? "$system $IRC_OUTPUT_INSTRUCTION"
        : $IRC_OUTPUT_INSTRUCTION;
}

1;
